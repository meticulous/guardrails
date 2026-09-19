# frozen_string_literal: true

require "guardrails/report/severity"

RSpec.describe Guardrails::Report::Severity do
  describe ".parse" do
    it "defaults to everything when unset or blank" do
      expect(described_class.parse(nil)).to eq(:suggestion)
      expect(described_class.parse("  ")).to eq(:suggestion)
    end

    it "accepts the severity names, singular or plural, in any case" do
      expect(described_class.parse("error")).to eq(:error)
      expect(described_class.parse("Errors")).to eq(:error)
      expect(described_class.parse(" WARNING ")).to eq(:warning)
      expect(described_class.parse("suggest")).to eq(:suggestion)
      expect(described_class.parse("all")).to eq(:suggestion)
    end

    it "rejects anything else loudly — a typo must not silently un-gate CI" do
      expect { described_class.parse("eror") }.to raise_error(ArgumentError, /SEVERITY=eror isn't a severity/)
      expect { described_class.parse("1") }.to raise_error(ArgumentError)
    end
  end

  it "treats the floor as inclusive" do
    expect(described_class.include?(:error, :error)).to be(true)
    expect(described_class.include?(:warning, :error)).to be(false)
    expect(described_class.include?(:warning, :warning)).to be(true)
    expect(described_class.include?(:suggestion, :warning)).to be(false)
    expect(described_class.include?(:suggestion, :suggestion)).to be(true)
  end

  it "lists what a floor mutes" do
    expect(described_class.muted(:suggestion)).to eq([])
    expect(described_class.muted(:warning)).to eq([:suggestion])
    expect(described_class.muted(:error)).to eq(%i[warning suggestion])
  end
end
