# frozen_string_literal: true

require "stringio"
require "guardrails/report/summary"

RSpec.describe Guardrails::Report::Summary do
  let(:output) { StringIO.new }
  let(:style) { Guardrails::Report::Style.new(io: output, force: false) }

  def entry(**attrs)
    Guardrails::Report::Summary::Entry.new(**attrs)
  end

  describe "#render" do
    it "is silent when no entries have findings" do
      described_class.new(entries: [], output: output, style: style).render
      expect(output.string).to eq("")
    end

    it "is silent when every entry has count: 0" do
      entries = [entry(category: "raw_color", count: 0, severity: :error)]
      described_class.new(entries: entries, output: output, style: style).render
      expect(output.string).to eq("")
    end

    it "renders a header line with the total count" do
      entries = [
        entry(category: "raw_color", count: 3, severity: :error),
        entry(category: "pattern", count: 2, severity: :suggestion)
      ]
      described_class.new(entries: entries, output: output, style: style).render

      expect(output.string).to include("Guardrails audit  —  5 findings")
    end

    it "uses 'finding' (singular) when there's exactly one" do
      entries = [entry(category: "a11y", count: 1, severity: :error)]
      described_class.new(entries: entries, output: output, style: style).render

      expect(output.string).to include("1 finding")
      expect(output.string).not_to include("1 findings")
    end

    it "groups entries by severity in error → warning → suggestion order" do
      entries = [
        entry(category: "pattern", count: 2, severity: :suggestion),
        entry(category: "raw_color", count: 5, severity: :error),
        entry(category: "helper_recommended", count: 3, severity: :warning)
      ]
      described_class.new(entries: entries, output: output, style: style).render

      err_idx = output.string.index("ERROR")
      warn_idx = output.string.index("WARNING")
      sugg_idx = output.string.index("SUGGEST")

      expect(err_idx).to be < warn_idx
      expect(warn_idx).to be < sugg_idx
    end

    it "shows category, count, and unit per entry" do
      entries = [entry(category: "similar partials", count: 820, severity: :suggestion, unit: "groups")]
      described_class.new(entries: entries, output: output, style: style).render

      expect(output.string).to include("similar partials")
      expect(output.string).to include("820 groups")
    end

    it "marks auto-fix availability when set" do
      entries = [entry(category: "raw_color", count: 3, severity: :error, auto_fix: true)]
      described_class.new(entries: entries, output: output, style: style).render

      expect(output.string).to include("[auto-fix available]")
    end

    it "shows a short action hint when no auto-fix flag is set" do
      entries = [entry(category: "pattern", count: 2, severity: :suggestion,
                       unit: "candidates", action: "consider extracting partials")]
      described_class.new(entries: entries, output: output, style: style).render

      expect(output.string).to include("consider extracting partials")
    end

    it "sorts within a severity group by count desc" do
      entries = [
        entry(category: "small", count: 3, severity: :error),
        entry(category: "biggest", count: 100, severity: :error),
        entry(category: "medium", count: 47, severity: :error)
      ]
      described_class.new(entries: entries, output: output, style: style).render

      big_idx = output.string.index("biggest")
      med_idx = output.string.index("medium")
      small_idx = output.string.index("small")
      expect(big_idx).to be < med_idx
      expect(med_idx).to be < small_idx
    end

    it "rolls up category and finding totals per severity group" do
      entries = [
        entry(category: "raw_color", count: 5, severity: :error),
        entry(category: "a11y", count: 3, severity: :error)
      ]
      described_class.new(entries: entries, output: output, style: style).render

      # "2 categories, 8 findings" — both totals shown
      expect(output.string).to include("2 categories, 8 findings")
    end

    it "skips a severity group with zero qualifying entries" do
      entries = [entry(category: "raw_color", count: 3, severity: :error)]
      described_class.new(entries: entries, output: output, style: style).render

      expect(output.string).not_to include("WARNING")
      expect(output.string).not_to include("SUGGEST")
    end
  end

  describe "with colors forced on" do
    let(:colored_style) { Guardrails::Report::Style.new(io: output, force: true) }

    it "wraps the auto-fix marker in green ANSI" do
      entries = [entry(category: "raw_color", count: 1, severity: :error, auto_fix: true)]
      described_class.new(entries: entries, output: output, style: colored_style).render

      expect(output.string).to include("\e[32m[auto-fix available]\e[0m")
    end

    it "uses box-drawing characters for the header bar" do
      entries = [entry(category: "raw_color", count: 1, severity: :error)]
      described_class.new(entries: entries, output: output, style: colored_style).render

      expect(output.string).to include("═")
    end
  end
end
