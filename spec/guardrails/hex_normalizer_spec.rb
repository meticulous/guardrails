# frozen_string_literal: true

require "guardrails/hex_normalizer"

RSpec.describe Guardrails::HexNormalizer do
  describe ".normalize" do
    it "lowercases hex" do
      expect(described_class.normalize("#FFAA33")).to eq("#ffaa33")
    end

    it "expands 3-char shorthand to 6-char" do
      expect(described_class.normalize("#fa3")).to eq("#ffaa33")
    end

    it "strips alpha from 4-char shorthand" do
      expect(described_class.normalize("#fa3a")).to eq("#ffaa33")
    end

    it "strips alpha from 8-char hex" do
      expect(described_class.normalize("#ffaa33aa")).to eq("#ffaa33")
    end

    it "leaves 7-char hex canonical" do
      expect(described_class.normalize("#ffaa33")).to eq("#ffaa33")
    end

    it "passes through non-hex values lowercased" do
      expect(described_class.normalize("rgb(255, 0, 0)")).to eq("rgb(255, 0, 0)")
    end
  end

  describe ".distance" do
    it "returns 0 for identical normalized values" do
      expect(described_class.distance("#fa3", "#FFAA33")).to eq(0)
    end

    it "returns 1 for a one-channel-off color" do
      expect(described_class.distance("#0066ff", "#0066fe")).to eq(1)
    end

    it "returns the max per-channel difference" do
      expect(described_class.distance("#000000", "#0a0500")).to eq(10)
    end

    it "ignores alpha differences" do
      expect(described_class.distance("#ffaa33", "#ffaa33aa")).to eq(0)
    end

    it "returns nil when either value isn't a hex literal" do
      expect(described_class.distance("rgb(0,0,0)", "#000000")).to be_nil
      expect(described_class.distance("#000000", "rgb(0,0,0)")).to be_nil
    end
  end
end
