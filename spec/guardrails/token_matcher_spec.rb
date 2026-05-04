# frozen_string_literal: true

require "guardrails/token_matcher"
require "guardrails/tokens"

RSpec.describe Guardrails::TokenMatcher do
  def token(name:, value:, syntax: :css_var)
    Guardrails::Tokens::Token.new(
      name: name, value: value, syntax: syntax, file: "tokens.css", line: 1
    )
  end

  describe "#match" do
    it "returns nil for nil input" do
      expect(described_class.new([]).match(nil)).to be_nil
    end

    it "returns nil when there are no tokens" do
      expect(described_class.new([]).match("#0066ff")).to be_nil
    end

    it "returns an exact match when one exists" do
      tokens = [token(name: "primary", value: "#0066ff")]

      m = described_class.new(tokens).match("#0066ff")

      expect(m.kind).to eq(:exact)
      expect(m.distance).to eq(0)
      expect(m.token.name).to eq("primary")
    end

    it "matches normalized hex (case + short form)" do
      tokens = [token(name: "secondary", value: "#FFAA33")]

      m = described_class.new(tokens).match("#fa3")
      expect(m.kind).to eq(:exact)
    end

    it "returns a near match within the default threshold" do
      tokens = [token(name: "primary", value: "#0066ff")]

      m = described_class.new(tokens).match("#0066fe")
      expect(m.kind).to eq(:near)
      expect(m.distance).to eq(1)
      expect(m.token.name).to eq("primary")
    end

    it "returns nil for matches beyond the threshold" do
      tokens = [token(name: "primary", value: "#0066ff")]

      expect(described_class.new(tokens).match("#abcdef")).to be_nil
    end

    it "prefers exact over near when both exist" do
      tokens = [
        token(name: "primary", value: "#0066ff"),
        token(name: "primary-soft", value: "#0066fe")
      ]

      m = described_class.new(tokens).match("#0066ff")
      expect(m.kind).to eq(:exact)
      expect(m.token.name).to eq("primary")
    end

    it "honors a custom near-match threshold" do
      tokens = [token(name: "primary", value: "#0066ff")]

      strict = described_class.new(tokens, near_match_threshold: 0).match("#0066fe")
      lax = described_class.new(tokens, near_match_threshold: 10).match("#0066fa")

      expect(strict).to be_nil
      expect(lax.kind).to eq(:near)
    end
  end
end
