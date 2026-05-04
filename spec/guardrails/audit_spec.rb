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
