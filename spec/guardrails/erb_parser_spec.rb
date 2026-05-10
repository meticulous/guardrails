# frozen_string_literal: true

require "guardrails/erb_parser"

RSpec.describe Guardrails::ErbParser do
  describe ".parse" do
    it "returns a successful Result for valid ERB" do
      result = described_class.parse("<button><%= label %></button>")

      expect(result.success?).to be(true)
      expect(result.document).to respond_to(:compact_child_nodes)
    end

    it "returns a Result with errors for malformed ERB instead of crashing" do
      # Unclosed tag — Herb produces errors but should not raise.
      result = described_class.parse("<button>")

      expect(result.success?).to be(false)
      expect(result.errors).not_to be_empty
      expect(result.document).to respond_to(:compact_child_nodes)
    end

    it "always returns a document that responds to compact_child_nodes (no nil-check needed by callers)" do
      result = described_class.parse("")

      expect(result.document).to respond_to(:compact_child_nodes)
      expect(Array(result.document.compact_child_nodes)).to eq([])
    end
  end

  describe ".each_node" do
    it "yields the root and every descendant" do
      result = described_class.parse("<div><span>x</span></div>")
      classes = []
      described_class.each_node(result.document) { |n| classes << n.class.name.split("::").last }

      expect(classes).to include("DocumentNode", "HTMLElementNode")
    end
  end

  describe ".start_position" do
    it "returns 1-indexed line and 1-indexed column for a node" do
      result = described_class.parse("<button>x</button>")
      button = result.document.compact_child_nodes.first

      line, column = described_class.start_position(button)
      expect(line).to eq(1)
      expect(column).to eq(1)
    end
  end
end
