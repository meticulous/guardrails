# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/audit"
require "guardrails/feed_ramp"
require "guardrails/report/run"

RSpec.describe "Audit component_match" do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  def write_file(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def seed_components
    write_file("app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\nend\n")
    write_file("app/components/button_component.html.erb",
               %(<button type="button" class="button button--<%= @variant %>" aria-label="<%= @label %>"><%= content %></button>\n))
    write_file("app/components/panel_component.rb", "class PanelComponent < ViewComponent::Base\nend\n")
    write_file("app/components/panel_component.html.erb",
               %(<div class="flex items-center gap-2 rounded-lg border"><%= content %></div>\n))
    write_file("test/components/previews/button_component_preview.rb", <<~RUBY)
      class ButtonComponentPreview < ViewComponent::Preview
        def default
          render(ButtonComponent.new(variant: :primary)) { "Save" }
        end
      end
    RUBY
    write_file("test/components/previews/panel_component_preview.rb", <<~RUBY)
      class PanelComponentPreview < ViewComponent::Preview
        def default; end
      end
    RUBY
  end

  def write_manifest
    Guardrails::FeedRamp::Manifest.new(root: @root).write
  end

  def matches(audit = Guardrails::Audit.new(root: @root, output: StringIO.new))
    audit.run.select { |v| v.type == :component_match }
  end

  before { seed_components }

  it "stays silent until there's a manifest" do
    write_file("app/views/pages/home.html.erb", %(<button class="button">Go</button>\n))
    expect(matches).to be_empty
  end

  context "with a manifest" do
    before { write_manifest }

    it "flags markup carrying a component's signature class, with its example as the fix" do
      write_file("app/views/pages/home.html.erb", %(<p>Hi</p>\n<button type="button" class="button button--primary">Save</button>\n))
      audit = Guardrails::Audit.new(root: @root, output: StringIO.new)

      found = matches(audit)
      expect(found.map { |v| [v.file, v.line, v.value] }).to eq([["app/views/pages/home.html.erb", 2, "ButtonComponent"]])
      finding = audit.categories(found).first.findings.first
      expect(finding).to have_attributes(severity: :warning,
                                         title: %(component_match: <button type="button" class="button button--primary"> looks like ButtonComponent),
                                         suggestion: "render ButtonComponent instead, e.g. render(ButtonComponent.new(variant: :primary)) { \"Save\" }")
    end

    it "flags markup carrying most of a long class list, whatever its order and extras" do
      write_file("app/views/pages/a.html.erb", %(<div class="mt-4 border rounded-lg gap-2 flex">x</div>\n))
      write_file("app/views/pages/b.html.erb", %(<div class="flex items-center gap-2">x</div>\n))
      write_file("app/views/pages/c.html.erb", %(<section class="flex items-center gap-2 rounded-lg border">x</section>\n))

      expect(matches.map { |v| [v.file, v.value] }).to eq([["app/views/pages/a.html.erb", "PanelComponent"]])
    end

    it "matches a signature class on any tag, but a class list only on the component's tag" do
      write_file("app/views/pages/a.html.erb", %(<a href="/x" class="button">Go</a>\n))
      write_file("app/views/pages/b.html.erb", %(<span class="flex items-center gap-2 rounded-lg border">x</span>\n))

      expect(matches.map { |v| [v.file, v.value] }).to eq([["app/views/pages/a.html.erb", "ButtonComponent"]])
    end

    it "doesn't match a component's own template, or a short generic class list" do
      write_file("app/components/chip_component.rb", "class ChipComponent < ViewComponent::Base\nend\n")
      write_file("app/components/chip_component.html.erb", %(<span class="px-2 rounded">x</span>\n))
      write_manifest
      write_file("app/views/pages/a.html.erb", %(<span class="px-2 rounded">x</span>\n))

      expect(matches).to be_empty
    end

    it "matches inside another component's template" do
      write_file("app/components/modal_component.rb", "class ModalComponent < ViewComponent::Base\nend\n")
      write_file("app/components/modal_component.html.erb", %(<dialog>\n  <button class="button">Close</button>\n</dialog>\n))

      expect(matches.map { |v| [v.file, v.line] }).to eq([["app/components/modal_component.html.erb", 2]])
    end

    it "checks a template given as source, as the agent hooks do" do
      audit = Guardrails::Audit.new(root: @root, output: StringIO.new)
      expect(audit.scan_source("app/views/pages/new.html.erb", %(<button class="button">Go</button>\n)).map(&:type))
        .to eq([:component_match])
      expect(audit.scan_source("app/components/button_component.html.erb").map(&:type)).not_to include(:component_match)
    end

    describe "severity from guardrails.yml" do
      before { write_file("app/views/pages/home.html.erb", %(<button class="button">Go</button>\n)) }

      def run
        Guardrails::Report::Run.new(root: @root).call
      end

      it "is a warning by default, and fails the audit" do
        expect(run.summary_entries.find { |e| e.category == "component_match" }).to have_attributes(count: 1, severity: :warning)
        expect(run).to be_failing
      end

      it "can be lowered to a suggestion, which reports without failing" do
        write_file("guardrails.yml", "guardrails:\n  feed_ramp:\n    component_match: suggestion\n")
        expect(run.findings.map { |f| [f.category, f.severity] }).to eq([["component_match", :suggestion]])
        expect(run).not_to be_failing
        expect(Guardrails::Report::Run.new(root: @root, min_severity: :warning).call.findings).to be_empty
      end

      it "can be raised to an error or turned off" do
        write_file("guardrails.yml", "guardrails:\n  feed_ramp:\n    component_match:\n      severity: error\n")
        expect(run.findings.map(&:severity)).to eq([:error])

        write_file("guardrails.yml", "guardrails:\n  feed_ramp:\n    component_match:\n      severity: off\n")
        expect(run.findings).to be_empty
        expect(run).not_to be_failing
      end

      it "takes min_classes and coverage" do
        write_file("guardrails.yml", "guardrails:\n  feed_ramp:\n    component_match:\n      min_classes: 2\n      coverage: 0.5\n")
        write_file("app/views/pages/b.html.erb", %(<div class="flex items-center gap-2">x</div>\n))
        expect(run.findings.map { |f| f.locations.first.file }).to include("app/views/pages/b.html.erb")
      end

      it "rejects a severity it doesn't know" do
        write_file("guardrails.yml", "guardrails:\n  feed_ramp:\n    component_match: warn\n")
        expect { run }.to raise_error(ArgumentError, /component_match severity "warn"/)
      end
    end
  end
end
