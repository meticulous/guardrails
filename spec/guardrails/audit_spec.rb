# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/audit"

RSpec.describe Guardrails::Audit do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_view(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  def run_audit
    described_class.new(root: root, output: StringIO.new).run
  end

  describe "inline style detection" do
    it "returns no violations on a clean view tree" do
      write_view "app/views/welcome/index.html.erb", "<h1>Hello</h1>"

      expect(run_audit).to be_empty
    end

    it "flags style=\"...\" on an HTML element" do
      write_view "app/views/welcome/index.html.erb", <<~ERB
        <h1>Hello</h1>
        <p style="color: red">Greetings</p>
      ERB

      violations = run_audit
      expect(violations.length).to eq(1)
      expect(violations.first).to have_attributes(
        type: :inline_style,
        file: "app/views/welcome/index.html.erb",
        line: 2
      )
    end

    it "flags style='...' with single quotes" do
      write_view "app/views/posts/show.html.erb", "<div style='font-size: 12px'>x</div>"

      violations = run_audit
      expect(violations.length).to eq(1)
      expect(violations.first.type).to eq(:inline_style)
    end

    it "ignores Ruby `style:` symbol arguments inside ERB blocks" do
      write_view "app/views/posts/show.html.erb", <<~ERB
        <%= form.text_field :name, style: "color: red" %>
      ERB

      expect(run_audit).to be_empty
    end

    it "preserves correct line numbers when masking ERB" do
      write_view "app/views/posts/show.html.erb", <<~ERB
        <% items.each do |i| %>
          <%= i.name %>
        <% end %>
        <p style="margin: 0">x</p>
      ERB

      violations = run_audit
      expect(violations.length).to eq(1)
      expect(violations.first.line).to eq(4)
    end

    it "captures the full inline-style snippet" do
      write_view "app/views/posts/show.html.erb", <<~ERB
        <div style="background: #fff; color: red">x</div>
      ERB

      expect(run_audit.first.snippet).to include('style="background: #fff; color: red"')
    end

    it "scans app/components/**/*.html.erb" do
      write_view "app/components/button_component.html.erb", '<button style="padding: 4px">x</button>'

      expect(run_audit.length).to eq(1)
    end

    it "flags multiple violations across files" do
      write_view "app/views/a.html.erb", '<a style="color: red">x</a>'
      write_view "app/views/b.html.erb", '<b style="color: blue">y</b>'

      expect(run_audit.length).to eq(2)
    end
  end

  describe "raw color detection" do
    it "flags hex literals in attribute values" do
      write_view "app/views/icons/show.html.erb", '<svg fill="#fa3"></svg>'

      violations = run_audit
      expect(violations.length).to eq(1)
      expect(violations.first.type).to eq(:raw_color)
    end

    it "flags 6-digit and 8-digit hex literals" do
      write_view "app/views/a.html.erb", '<svg fill="#0066ff"></svg>'
      write_view "app/views/b.html.erb", '<svg fill="#0066ff80"></svg>'

      types = run_audit.map(&:type)
      expect(types).to eq([:raw_color, :raw_color])
    end

    it "flags rgb() and rgba() literals in attribute values" do
      write_view "app/views/x.html.erb", '<div data-color="rgb(255, 0, 0)"></div>'
      write_view "app/views/y.html.erb", '<div data-color="rgba(0, 0, 0, 0.5)"></div>'

      expect(run_audit.map(&:type)).to eq([:raw_color, :raw_color])
    end

    it "does not flag hex inside body text" do
      write_view "app/views/post.html.erb", "<p>The brand color is #fa3 today</p>"

      expect(run_audit).to be_empty
    end

    it "does not flag hex inside style= attributes (already covered by inline_style)" do
      write_view "app/views/x.html.erb", '<p style="color: #fa3">x</p>'

      types = run_audit.map(&:type)
      expect(types).to eq([:inline_style])
    end

    it "does not flag hex inside ERB output blocks" do
      write_view "app/views/x.html.erb", '<%= "color: #fa3" %>'

      expect(run_audit).to be_empty
    end

    it "flags multiple hex literals on the same line" do
      write_view "app/views/x.html.erb", '<svg fill="#fa3" stroke="#0066ff"></svg>'

      expect(run_audit.length).to eq(2)
    end

    it "does not flag hex-shaped URL fragments in href attributes" do
      write_view "app/views/x.html.erb", '<a href="#section">Top</a><a href="#abc">Anchor</a>'

      expect(run_audit).to be_empty
    end

    it "does not flag hex-shaped IDs in non-color data attributes" do
      write_view "app/views/x.html.erb", '<div data-id="#abc123" data-fragment="#abcdef">x</div>'

      expect(run_audit).to be_empty
    end

    it "handles UTF-8 content (e.g. em-dashes) without raising" do
      write_view "app/views/x.html.erb", <<~ERB
        <p>Brand color — pretty cool</p>
        <svg fill="#fa3"></svg>
      ERB

      violations = run_audit
      expect(violations.length).to eq(1)
      expect(violations.first.type).to eq(:raw_color)
    end
  end

  describe "tailwind arbitrary value detection" do
    it "flags bg-[#fa3] in a class attribute" do
      write_view "app/views/x.html.erb", '<div class="bg-[#fa3] text-white">x</div>'

      violations = run_audit
      expect(violations.length).to eq(1)
      expect(violations.first.type).to eq(:tailwind_arbitrary)
    end

    it "flags multiple arbitrary values in one class string" do
      write_view "app/views/x.html.erb", '<div class="bg-[#fa3] text-[14px] p-[7px]">x</div>'

      types = run_audit.map(&:type)
      expect(types).to eq([:tailwind_arbitrary, :tailwind_arbitrary, :tailwind_arbitrary])
    end

    it "flags arbitrary values in single-quoted class attributes" do
      write_view "app/views/x.html.erb", "<div class='bg-[#fa3]'>x</div>"

      expect(run_audit.length).to eq(1)
    end

    it "flags arbitrary variants like [&>div]:" do
      write_view "app/views/x.html.erb", '<div class="[&>div]:bg-red-500">x</div>'

      expect(run_audit.length).to eq(1)
    end

    it "does not flag bracketed text outside class attributes" do
      write_view "app/views/x.html.erb", '<div data-foo="[bar]">x</div>'

      expect(run_audit).to be_empty
    end

    it "does not flag arbitrary values inside ERB output blocks" do
      write_view "app/views/x.html.erb", '<%= "class=\"bg-[#fa3]\"" %>'

      expect(run_audit).to be_empty
    end

    it "reports the column where the arbitrary value starts" do
      write_view "app/views/x.html.erb", '<div class="text-white bg-[#fa3]">x</div>'

      v = run_audit.first
      expect(v.type).to eq(:tailwind_arbitrary)
      expect(v.column).to eq(27)
    end
  end

  describe "suggest mode" do
    it "writes a suggestions markdown when suggest is true" do
      write_view "app/views/x.html.erb", '<p style="color: red">x</p>'

      described_class.new(root: root, output: StringIO.new, suggest: true).run

      matching = Dir.glob(root.join("doc/guardrails-suggestions-*.md"))
      expect(matching.length).to eq(1)
    end

    it "does not write a suggestions markdown when suggest is false" do
      write_view "app/views/x.html.erb", '<p style="color: red">x</p>'

      described_class.new(root: root, output: StringIO.new, suggest: false).run

      expect(Dir.glob(root.join("doc/guardrails-suggestions-*.md"))).to be_empty
    end
  end

  describe "json output" do
    it "emits valid JSON when format is :json" do
      require "json"
      write_view "app/views/x.html.erb", '<p style="color: red">x</p>'

      output = StringIO.new
      described_class.new(root: root, output: output, format: :json).run

      parsed = JSON.parse(output.string)
      expect(parsed["summary"]["total"]).to eq(1)
      expect(parsed["summary"]["files"]).to eq(1)
      expect(parsed["violations"].first["type"]).to eq("inline_style")
      expect(parsed["violations"].first["file"]).to eq("app/views/x.html.erb")
      expect(parsed["violations"].first["line"]).to eq(1)
    end

    it "emits valid JSON for an empty violation set" do
      require "json"

      output = StringIO.new
      described_class.new(root: root, output: output, format: :json).run

      parsed = JSON.parse(output.string)
      expect(parsed["summary"]["total"]).to eq(0)
      expect(parsed["violations"]).to eq([])
    end
  end

  describe "configurable near_match_threshold" do
    def configure_tokens(near_match_threshold:)
      root.join("guardrails.yml").write({
        "guardrails" => {
          "tokens" => {
            "colors_file" => "tokens.css",
            "near_match_threshold" => near_match_threshold
          }
        }
      }.to_yaml)
      root.join("tokens.css").write(":root { --primary: #0066ff; }\n")
    end

    it "respects a custom near_match_threshold from guardrails.yml in suggest mode" do
      configure_tokens(near_match_threshold: 0) # exact-only — disable near matches
      write_view "app/views/x.html.erb", '<svg fill="#0066fe"></svg>' # 1 channel off

      described_class.new(root: root, output: StringIO.new, suggest: true).run

      md = Dir.glob(root.join("doc/guardrails-suggestions-*.md")).first
      content = File.read(md, encoding: Encoding::UTF_8)
      expect(content).not_to include("near match")
    end

    it "still emits near-match suggestions at the default threshold (4)" do
      configure_tokens(near_match_threshold: 4)
      write_view "app/views/x.html.erb", '<svg fill="#0066fe"></svg>'

      described_class.new(root: root, output: StringIO.new, suggest: true).run

      md = Dir.glob(root.join("doc/guardrails-suggestions-*.md")).first
      content = File.read(md, encoding: Encoding::UTF_8)
      expect(content).to include("near match")
    end
  end

  describe "configurable scan_paths and ignore" do
    def configure(audit_config)
      root.join("guardrails.yml").write({ "guardrails" => { "audit" => audit_config } }.to_yaml)
    end

    it "honors scan_paths from guardrails.yml" do
      configure("scan_paths" => ["lib/templates"])
      write_view "lib/templates/welcome.html.erb", '<svg fill="#0066ff"></svg>'
      write_view "app/views/welcome.html.erb", '<svg fill="#0066ff"></svg>'

      violations = run_audit
      expect(violations.length).to eq(1)
      expect(violations.first.file).to eq("lib/templates/welcome.html.erb")
    end

    it "honors ignore from guardrails.yml" do
      configure("ignore" => ["app/views/layouts"])
      write_view "app/views/layouts/application.html.erb", '<svg fill="#0066ff"></svg>'
      write_view "app/views/welcome.html.erb", '<svg fill="#0066ff"></svg>'

      violations = run_audit
      expect(violations.length).to eq(1)
      expect(violations.first.file).to eq("app/views/welcome.html.erb")
    end

    it "falls back to defaults when no audit config is set" do
      write_view "app/views/x.html.erb", '<svg fill="#0066ff"></svg>'
      write_view "app/components/y.html.erb", '<svg fill="#0066ff"></svg>'

      expect(run_audit.length).to eq(2)
    end
  end

  describe "report output" do
    it "prints a clean summary when no violations are found" do
      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("no violations found")
    end

    it "prints violation details when violations are found" do
      write_view "app/views/x.html.erb", '<i style="color: red">x</i>'
      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("1 violation found")
      expect(output.string).to include("[inline_style]")
      expect(output.string).to include("app/views/x.html.erb:1")
    end
  end
end
