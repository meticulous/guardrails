# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/a11y_audit"

RSpec.describe Guardrails::A11yAudit do
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

  describe "image_alt" do
    it "flags <img> without an alt attribute" do
      write_view "app/views/x.html.erb", '<img src="logo.png">'

      findings = run_audit
      expect(findings.length).to eq(1)
      expect(findings.first.rule).to eq(:image_alt)
    end

    it "considers an empty alt acceptable (decorative image convention)" do
      write_view "app/views/x.html.erb", '<img src="logo.png" alt="">'

      expect(run_audit).to be_empty
    end

    it "considers a populated alt fine" do
      write_view "app/views/x.html.erb", '<img src="logo.png" alt="Company logo">'

      expect(run_audit).to be_empty
    end
  end

  describe "button_name" do
    it "flags an empty <button>" do
      write_view "app/views/x.html.erb", '<button></button>'

      findings = run_audit
      expect(findings.first.rule).to eq(:button_name)
    end

    it "flags <button> with only whitespace" do
      write_view "app/views/x.html.erb", '<button>   </button>'

      expect(run_audit.first.rule).to eq(:button_name)
    end

    it "considers a button with text fine" do
      write_view "app/views/x.html.erb", '<button>Save</button>'

      expect(run_audit).to be_empty
    end

    it "considers a button with aria-label fine" do
      write_view "app/views/x.html.erb", '<button aria-label="Close"></button>'

      expect(run_audit).to be_empty
    end

    it "considers a button with aria-labelledby fine" do
      write_view "app/views/x.html.erb", '<button aria-labelledby="hdr"></button>'

      expect(run_audit).to be_empty
    end
  end

  describe "link_name" do
    it "flags <a href> without text or aria-label" do
      write_view "app/views/x.html.erb", '<a href="/x"></a>'

      expect(run_audit.first.rule).to eq(:link_name)
    end

    it "considers <a> with text fine" do
      write_view "app/views/x.html.erb", '<a href="/x">Click</a>'

      expect(run_audit).to be_empty
    end

    it "considers <a> with aria-label fine" do
      write_view "app/views/x.html.erb", '<a href="/x" aria-label="Profile"></a>'

      expect(run_audit).to be_empty
    end

    it "considers <a> with title attribute fine" do
      write_view "app/views/x.html.erb", '<a href="/x" title="Home"></a>'

      expect(run_audit).to be_empty
    end

    it "ignores <a> without href (anchors)" do
      write_view "app/views/x.html.erb", '<a name="top"></a>'

      expect(run_audit).to be_empty
    end
  end

  describe "input_label" do
    it "flags <input type=text> without a label" do
      write_view "app/views/x.html.erb", '<input type="text" name="email">'

      expect(run_audit.first.rule).to eq(:input_label)
    end

    it "considers <input> with aria-label fine" do
      write_view "app/views/x.html.erb", '<input type="text" aria-label="Email">'

      expect(run_audit).to be_empty
    end

    it "considers <input> with a matching <label for> fine" do
      write_view "app/views/x.html.erb", <<~ERB
        <label for="email">Email</label>
        <input type="text" id="email">
      ERB

      expect(run_audit).to be_empty
    end

    it "ignores hidden, submit, button, reset, image inputs" do
      write_view "app/views/h.html.erb", '<input type="hidden" name="t">'
      write_view "app/views/s.html.erb", '<input type="submit" value="Go">'
      write_view "app/views/b.html.erb", '<input type="button" value="Go">'
      write_view "app/views/r.html.erb", '<input type="reset" value="Reset">'

      expect(run_audit).to be_empty
    end
  end

  describe "report" do
    it "is silent when there are no findings" do
      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to eq("")
    end

    it "ignores ERB output blocks" do
      write_view "app/views/x.html.erb", '<%= "<img>" %>'

      expect(run_audit).to be_empty
    end
  end
end
