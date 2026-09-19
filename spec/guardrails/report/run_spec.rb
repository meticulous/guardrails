# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "guardrails/report/run"

RSpec.describe Guardrails::Report::Run do
  let(:root) { Pathname(File.expand_path("../../../examples/demo", __dir__)) }

  subject(:run) { described_class.new(root: root).call }

  it "returns itself from #call so construction chains" do
    expect(run).to be_a(described_class)
  end

  it "runs every always-on detector against the root" do
    expect(run.violations.map(&:type).tally).to include(raw_color: 3, tailwind_arbitrary: 2, inline_style: 1)
    expect(run.stimulus.orphaned).to eq(["missing"])
    expect(run.stimulus.dead).to eq(["dead"])
    expect(run.similarity.length).to eq(2)
    expect(run.a11y.length).to eq(3)
  end

  it "leaves opt-in detectors empty when not enabled" do
    expect(run.a11y_deep).to eq([])
    expect(run.visual_diff).to eq([])
  end

  it "captures detector output in #body instead of printing it" do
    expect { run }.not_to output.to_stdout
    expect(run.body).to include("inline_style")
  end

  it "emits no ANSI codes in #body when no style is given" do
    expect(run.body).not_to match(/\e\[/)
  end

  it "threads a forced-color style through to every detector section" do
    style = Guardrails::Report::Style.new(io: StringIO.new, force: true)
    colored = described_class.new(root: root, style: style).call

    expect(colored.body).to match(/\e\[/)
  end

  describe "#summary_entries" do
    it "has one entry per category whose counts match the detector results" do
      counts = run.summary_entries.to_h { |e| [e.category, e.count] }

      expect(counts).to include(
        "raw_color" => 3, "tailwind_arbitrary" => 2, "inline_style" => 1,
        "a11y (static)" => 3, "similar partials" => 2, "a11y (deep)" => 0
      )
    end

    it "flags only the auto-fixable categories" do
      fixable = run.summary_entries.select(&:auto_fix).map(&:category)

      expect(fixable).to contain_exactly("raw_color", "tailwind_arbitrary")
    end
  end

  describe "#to_h" do
    it "keeps the FORMAT=json top-level shape" do
      expect(run.to_h.keys).to eq(
        %i[summary violations stimulus similar_partials view_components a11y a11y_deep patterns classitis visual_diff]
      )
    end

    it "reports summary counts consistent with the detail arrays" do
      payload = run.to_h

      expect(payload[:summary][:violations]).to eq(payload[:violations].length)
      expect(payload[:summary][:a11y]).to eq(payload[:a11y].length)
    end
  end

  describe "#categories" do
    it "normalizes every finding, in summary order, with counts matching the summary" do
      categories = run.categories
      summary = run.summary_entries.reject { |e| e.count.zero? }.to_h { |e| [e.category, e.count] }

      expect(categories.to_h { |c| [c.name, c.count] }).to eq(summary)
      expect(categories.map(&:severity).uniq).to eq(%i[error warning suggestion])
      expect(categories.first(3).map(&:name)).to eq(["raw_color", "a11y (static)", "tailwind_arbitrary"])
    end

    it "gives every finding a title, and a location wherever there's a file to point at" do
      expect(run.findings.length).to eq(20)
      expect(run.findings).to all(have_attributes(title: a_string_matching(/\S/)))
      expect(run.findings.reject { |f| f.locations.empty? }.length).to eq(20)
    end

    it "carries the same suggestions the text report prints" do
      run.findings.filter_map(&:suggestion).each do |suggestion|
        expect(run.body).to include(suggestion)
      end
    end

    it "serializes findings" do
      expect(run.findings.first.to_h).to include(
        category: "raw_color", severity: :error, auto_fix: true,
        locations: [{ file: "app/views/welcome/broken.html.erb", line: 7, column: 12 }]
      )
    end
  end

  describe ".from_env" do
    it "reads detector thresholds and opt-ins from the env hash" do
      defaults = described_class.from_env(root: root, env: {}).call
      tuned = described_class.from_env(root: root, env: {
        "SIMILARITY_THRESHOLD" => "1.01", "CLASSITIS_MIN_CLASSES" => "1", "CLASSITIS_MIN_OCCURRENCES" => "2"
      }).call

      expect([defaults.similarity.length, defaults.classitis.length]).to eq([2, 0])
      expect([tuned.similarity.length, tuned.classitis.length]).to eq([0, 2])
    end

    it "treats 1 / true / yes as on and anything else as off" do
      expect(described_class.truthy?("1")).to be(true)
      expect(described_class.truthy?("YES")).to be(true)
      expect(described_class.truthy?("0")).to be(false)
      expect(described_class.truthy?(nil)).to be(false)
    end
  end

  describe "min_severity" do
    let(:errors_only) { described_class.new(root: root, min_severity: :error).call }
    let(:no_suggestions) { described_class.new(root: root, min_severity: :warning).call }

    it "checks everything by default" do
      expect(run.min_severity).to eq(:suggestion)
      expect(run.muted_severities).to eq([])
    end

    it "keeps only errors at :error — in findings, summary, JSON, and the printed body alike" do
      expect(errors_only.findings.map(&:severity).uniq).to eq([:error])
      expect(errors_only.categories.map(&:name)).to eq(["raw_color", "a11y (static)", "tailwind_arbitrary"])
      expect(errors_only.summary_entries.reject { |e| e.count.zero? }.map(&:severity).uniq).to eq([:error])
      expect(errors_only.to_h[:summary]).to include(violations: 5, a11y: 3, stimulus_orphaned: 0, similar_partials: 0,
                                                    missing_previews: 0)
      expect(errors_only.body).not_to match(/! WARNING|i SUGGEST|\[warning\]|\[suggest\]|inline_style|helper_recommended/)
      expect(errors_only.muted_severities).to eq(%i[warning suggestion])
    end

    it "drops only suggestions at :warning" do
      expect(no_suggestions.findings.map(&:severity).uniq).to eq(%i[error warning])
      expect(no_suggestions.findings.length).to eq(18)
      expect(no_suggestions.similarity).to eq([])
      expect(no_suggestions.stimulus.orphaned).to eq(["missing"])
    end

    it "doesn't run detectors that can only produce muted findings" do
      expect(Guardrails::PartialSimilarity).not_to receive(:new)
      expect(Guardrails::CrossCodebasePatterns).not_to receive(:new)
      expect(Guardrails::StimulusAudit).not_to receive(:new)

      errors_only
    end

    it "lets a CI gate pass on a project whose only findings are below the floor" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/views"))
        File.write(File.join(dir, "app/views/page.html.erb"), %(<p style="margin: 3px">hi</p>\n))

        expect(described_class.new(root: dir).call).to be_failing
        expect(described_class.new(root: dir, min_severity: :error).call).not_to be_failing
      end
    end

    it "filters deep a11y findings by their axe impact" do
      axe = [{ "url" => "http://localhost/", "violations" => [
        { "id" => "color-contrast", "impact" => "serious", "description" => "contrast", "nodes" => [{ "target" => [".a"] }] },
        { "id" => "region", "impact" => "moderate", "description" => "landmark", "nodes" => [{ "target" => [".b"] }] },
        { "id" => "tabindex", "impact" => "minor", "description" => "tabindex", "nodes" => [{ "target" => [".c"] }] }
      ] }]
      Dir.mktmpdir do |dir|
        path = File.join(dir, "axe.json")
        File.write(path, JSON.generate(axe))
        rules = ->(floor) { described_class.new(root: dir, axe_json: path, min_severity: floor).call.a11y_deep.map(&:rule) }

        expect(rules.(:suggestion)).to eq(%w[color-contrast region tabindex])
        expect(rules.(:warning)).to eq(%w[color-contrast region])
        expect(rules.(:error)).to eq(%w[color-contrast])
      end
    end

    it "comes from SEVERITY via from_env, and rejects values it doesn't know" do
      expect(described_class.from_env(root: root, env: { "SEVERITY" => "error" }).min_severity).to eq(:error)
      expect(described_class.from_env(root: root, env: {}).min_severity).to eq(:suggestion)
      expect { described_class.from_env(root: root, env: { "SEVERITY" => "errror" }) }.to raise_error(ArgumentError)
    end
  end

  describe "#failing?" do
    it "is true when any error or warning detector has findings" do
      expect(run).to be_failing
    end

    it "is false for a root with nothing to audit" do
      Dir.mktmpdir do |dir|
        expect(described_class.new(root: dir).call).not_to be_failing
      end
    end
  end
end
