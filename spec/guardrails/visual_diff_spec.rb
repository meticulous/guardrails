# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/visual_diff"

RSpec.describe Guardrails::VisualDiff do
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:output) { StringIO.new }
  after do
    FileUtils.rm_rf(root)
    Guardrails.reset_configuration!
  end

  def write_screenshot(relative)
    full = root.join("doc/screenshots").join(relative)
    full.dirname.mkpath
    full.write("fake png bytes for #{relative}")
  end

  describe "#collect via snap_diff adapter (the default)" do
    it "returns empty when the screenshots directory doesn't exist" do
      expect(described_class.new(root: root, output: output).collect).to be_empty
    end

    it "returns empty when there are baselines but no diffs" do
      write_screenshot "homepage.png"
      write_screenshot "checkout/cart.png"

      expect(described_class.new(root: root, output: output).collect).to be_empty
    end

    it "emits one Finding per `*.diff.png` (excluding .heatmap.diff.png)" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"
      write_screenshot "homepage.heatmap.diff.png" # excluded — visualization companion

      findings = described_class.new(root: root, output: output).collect
      expect(findings.length).to eq(1)
      expect(findings.first.scenario).to eq("homepage")
    end

    it "scenario name reflects the nested path under the screenshots dir" do
      write_screenshot "checkout/cart.png"
      write_screenshot "checkout/cart.diff.png"

      finding = described_class.new(root: root, output: output).collect.first
      expect(finding.scenario).to eq("checkout/cart")
    end

    it "baseline_path points at the `<name>.png` sibling, diff_path at `<name>.diff.png`" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      finding = described_class.new(root: root, output: output).collect.first
      expect(finding.baseline_path).to eq("doc/screenshots/homepage.png")
      expect(finding.diff_path).to eq("doc/screenshots/homepage.diff.png")
    end

    it "leaves mismatch_ratio, viewport, url, selector, current_path nil for snap_diff" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      finding = described_class.new(root: root, output: output).collect.first
      expect(finding.mismatch_ratio).to be_nil
      expect(finding.viewport).to be_nil
      expect(finding.url).to be_nil
      expect(finding.selector).to be_nil
      expect(finding.current_path).to be_nil
    end

    it "honors the Configuration-set snap_diff_dir" do
      # When the user overrides snap_diff_dir via Guardrails.configure,
      # the adapter looks under that path instead of doc/screenshots.
      Guardrails.configure { |c| c.visual_diff.snap_diff_dir = "spec/screenshots" }
      custom = root.join("spec/screenshots/homepage.diff.png")
      custom.dirname.mkpath
      custom.write("fake")
      root.join("spec/screenshots/homepage.png").write("fake")

      findings = described_class.new(root: root, output: output).collect
      expect(findings.length).to eq(1)
    end
  end

  describe "#any_failing?" do
    it "treats nil mismatch_ratio (snap_diff) as unconditionally failing" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      audit = described_class.new(root: root, output: output)
      expect(audit.any_failing?(audit.collect)).to be true
    end

    it "returns false on an empty findings list" do
      audit = described_class.new(root: root, output: output)
      expect(audit.any_failing?([])).to be false
    end

    it "respects an explicit numeric threshold for adapters that emit a ratio" do
      f_low  = described_class::Finding.new(scenario: "a", mismatch_ratio: 0.01)
      f_high = described_class::Finding.new(scenario: "b", mismatch_ratio: 0.50)

      audit = described_class.new(root: root, output: output, threshold: 0.10)
      expect(audit.any_failing?([f_low])).to be false
      expect(audit.any_failing?([f_high])).to be true
    end
  end

  describe "#run (report output)" do
    it "is silent when there are no findings" do
      described_class.new(root: root, output: output).run
      expect(output.string).to eq("")
    end

    it "prints a header summary plus per-finding details" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      described_class.new(root: root, output: output).run
      expect(output.string).to include("Guardrails visual diff: 1 finding")
      expect(output.string).to include("adapter: snap_diff")
      expect(output.string).to include("threshold: 0.0")
      expect(output.string).to include("[diff present] homepage")
      expect(output.string).to include("baseline: doc/screenshots/homepage.png")
      expect(output.string).to include("diff:     doc/screenshots/homepage.diff.png")
    end

    it "prints mismatch percentages for findings with a numeric ratio" do
      f = described_class::Finding.new(scenario: "checkout", mismatch_ratio: 0.0237,
                                       diff_path: "tmp/diff.png", viewport: "desktop")
      audit = described_class.new(root: root, output: output)
      audit.send(:print_report, [f])
      expect(output.string).to include("[2.37% mismatch]")
      expect(output.string).to include("checkout (desktop)")
    end
  end

  describe "unknown adapters" do
    it "raises with a clear message when the configured adapter isn't recognized internally" do
      # Bypass Configuration#adapter= validation by passing through the
      # constructor; this guards the dispatch path in case the gem ever
      # registers an adapter without implementing its branch.
      audit = described_class.new(root: root, output: output, adapter: :not_yet_implemented)
      expect { audit.collect }.to raise_error(ArgumentError, /Unknown visual_diff adapter/)
    end
  end
end
