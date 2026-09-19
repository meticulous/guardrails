# frozen_string_literal: true

require "stringio"
require "guardrails/report/run"

# Every detector exposes `categories(result)`: its findings as
# detector-agnostic Report::Finding data. The demo-app cases live in
# run_spec; these cover the detectors the demo doesn't trigger, plus
# the contract they all share.
RSpec.describe "detector #categories" do
  let(:root) { Pathname(File.expand_path("../../../examples/demo", __dir__)) }
  let(:sink) { StringIO.new }

  it "returns nothing for empty results, from every detector" do
    expect(Guardrails::Audit.new(root: root, output: sink).categories([])).to eq([])
    expect(Guardrails::A11yAudit.new(root: root, output: sink).categories([])).to eq([])
    expect(Guardrails::PartialSimilarity.new(root: root, output: sink).categories([])).to eq([])
    expect(Guardrails::CrossCodebasePatterns.new(root: root, output: sink).categories([])).to eq([])
    expect(Guardrails::ClassItis.new(root: root, output: sink).categories([])).to eq([])
    expect(Guardrails::A11yDeep.new(input: [], output: sink).categories([])).to eq([])
    expect(Guardrails::VisualDiff.new(root: root, output: sink).categories([])).to eq([])
    expect(Guardrails::StimulusAudit.new(root: root, output: sink)
      .categories(Guardrails::StimulusAudit::Result.new(orphaned: [], dead: []))).to eq([])
    expect(Guardrails::ViewComponentAudit.new(root: root, output: sink)
      .categories(Guardrails::ViewComponentAudit::Result.new(missing_previews: [], orphan_slots: []))).to eq([])
  end

  describe Guardrails::StimulusAudit do
    subject(:detector) { described_class.new(root: root, output: sink) }

    it "locates every view line referencing an orphaned controller, and the file behind a dead one" do
      orphaned, dead = detector.categories(detector.run)

      expect(orphaned.findings.first.locations.map(&:to_s)).to eq(["app/views/welcome/broken.html.erb:31"])
      expect(dead.findings.first.locations.map(&:to_s)).to eq(["app/javascript/controllers/dead_controller.js"])
    end

    it "falls back to a file-level location for references split across lines" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/views"))
        File.write(File.join(dir, "app/views/split.html.erb"), "<%= tag.div data: {\n  controller: \"ghost\" } %>\n")
        local = described_class.new(root: dir, output: sink)
        result = local.run

        expect(result.orphaned).to eq(["ghost"])
        expect(local.categories(result).first.findings.first.locations.map(&:to_s)).to eq(["app/views/split.html.erb"])
      end
    end
  end

  describe Guardrails::ClassItis do
    it "carries every occurrence and the untruncated class list" do
      occurrences = (1..12).map { |n| described_class::Occurrence.new(file: "app/views/p#{n}.html.erb", line: n, column: 1) }
      classes = (1..30).map { |n| "utility-class-number-#{n}" }
      cluster = described_class::Cluster.new(tag: "div", classes: classes, occurrences: occurrences)
      finding = described_class.new(root: root, output: sink).categories([cluster]).first.findings.first

      expect(finding.title).to eq("<div> with 30 classes, 12 occurrences")
      expect(finding.locations.length).to eq(12)
      expect(finding.details.to_h["class"]).to eq(classes.join(" "))
      expect(finding.suggestion).to include("DivComponent")
    end
  end

  describe Guardrails::CrossCodebasePatterns do
    it "produces one finding per shape with all its occurrences" do
      occurrences = (1..4).map { |n| described_class::Occurrence.new(file: "app/views/t#{n}.html.erb", line: 3, column: 1, size: 5) }
      pattern = described_class::Pattern.new(fingerprint: "abc", shape: "table(thead,tbody)", size: 5, occurrences: occurrences)
      category = described_class.new(root: root, output: sink).categories([pattern]).first

      expect(category.name).to eq("cross-codebase patterns")
      expect(category.findings.first.files.length).to eq(4)
      expect(category.findings.first.suggestion).to include("_table.html.erb")
    end
  end

  describe Guardrails::A11yDeep do
    it "maps axe impact to per-finding severity and carries url / selector as details" do
      findings = [
        described_class::Finding.new(rule: "color-contrast", impact: "serious", description: "Low contrast",
                                     help_url: "https://dequeuniversity.com/x", url: "http://localhost/", selector: ".btn"),
        described_class::Finding.new(rule: "region", impact: "moderate", description: "No landmark", url: "http://localhost/")
      ]
      category = described_class.new(input: [], output: sink).categories(findings).first

      expect(category.findings.map(&:severity)).to eq(%i[error warning])
      expect(category.findings.first.locations).to be_empty
      expect(category.findings.first.details.to_h).to include("url" => "http://localhost/", "selector" => ".btn")
      expect(category.findings.last.suggestion).to be_nil
    end
  end

  describe Guardrails::VisualDiff do
    it "leads with the diff image as the thing to open" do
      finding = described_class::Finding.new(scenario: "checkout", viewport: "mobile", mismatch_ratio: 0.0312,
                                             baseline_path: "doc/screenshots/checkout.png",
                                             diff_path: "doc/screenshots/checkout.diff.png")
      normalized = described_class.new(root: root, output: sink).categories([finding]).first.findings.first

      expect(normalized.title).to eq("[3.12% mismatch] checkout (mobile)")
      expect(normalized.location.file).to eq("doc/screenshots/checkout.diff.png")
    end
  end
end
