# frozen_string_literal: true

require "stringio"
require "guardrails/init/prompter"

RSpec.describe Guardrails::Init::Prompter do
  def tty_io(text)
    io = StringIO.new(text)
    allow(io).to receive(:tty?).and_return(true)
    io
  end

  def non_tty_io
    io = StringIO.new
    allow(io).to receive(:tty?).and_return(false)
    io
  end

  describe "#ask" do
    it "returns the default silently when input is not a TTY" do
      output = StringIO.new
      result = described_class.new(input: non_tty_io, output: output).ask("Name?", default: "x")

      expect(result).to eq("x")
      expect(output.string).to eq("")
    end

    it "returns the default when the user accepts it (empty input)" do
      result = described_class.new(input: tty_io("\n"), output: StringIO.new).ask("Name?", default: "x")
      expect(result).to eq("x")
    end

    it "returns the user's input when they provide a value" do
      result = described_class.new(input: tty_io("foo\n"), output: StringIO.new).ask("Name?", default: "x")
      expect(result).to eq("foo")
    end

    it "displays the question with the default in brackets" do
      output = StringIO.new
      described_class.new(input: tty_io("\n"), output: output).ask("Name?", default: "x")

      expect(output.string).to include("Name? [x]:")
    end

    it "trims whitespace from the user's input" do
      result = described_class.new(input: tty_io("  bar  \n"), output: StringIO.new).ask("Q?", default: "x")
      expect(result).to eq("bar")
    end

    it "treats whitespace-only input as accepting the default" do
      result = described_class.new(input: tty_io("   \n"), output: StringIO.new).ask("Q?", default: "x")
      expect(result).to eq("x")
    end

    it "returns the default on EOF" do
      result = described_class.new(input: tty_io(""), output: StringIO.new).ask("Q?", default: "x")
      expect(result).to eq("x")
    end
  end

  describe "#choose" do
    let(:choices) { %w[notify fix leave] }

    it "returns the default silently when input is not a TTY" do
      output = StringIO.new
      result = described_class.new(input: non_tty_io, output: output)
                              .choose("Policy?", choices: choices, default: "notify")

      expect(result).to eq("notify")
      expect(output.string).to eq("")
    end

    it "accepts a numeric selection (1-based)" do
      result = described_class.new(input: tty_io("2\n"), output: StringIO.new)
                              .choose("?", choices: choices, default: "notify")
      expect(result).to eq("fix")
    end

    it "accepts the literal choice name" do
      result = described_class.new(input: tty_io("leave\n"), output: StringIO.new)
                              .choose("?", choices: choices, default: "notify")
      expect(result).to eq("leave")
    end

    it "returns the default on empty input" do
      result = described_class.new(input: tty_io("\n"), output: StringIO.new)
                              .choose("?", choices: choices, default: "notify")
      expect(result).to eq("notify")
    end

    it "re-prompts on invalid input then accepts a valid selection" do
      result = described_class.new(input: tty_io("garbage\nfix\n"), output: StringIO.new)
                              .choose("?", choices: choices, default: "notify")
      expect(result).to eq("fix")
    end

    it "rejects out-of-range numeric input" do
      result = described_class.new(input: tty_io("9\nleave\n"), output: StringIO.new)
                              .choose("?", choices: choices, default: "notify")
      expect(result).to eq("leave")
    end

    it "marks the default visually in the choice list" do
      output = StringIO.new
      described_class.new(input: tty_io("\n"), output: output)
                     .choose("?", choices: choices, default: "fix")

      expect(output.string).to match(/2\) fix.*default/)
    end

    it "returns the default on EOF mid-choose" do
      result = described_class.new(input: tty_io(""), output: StringIO.new)
                              .choose("?", choices: choices, default: "notify")
      expect(result).to eq("notify")
    end
  end
end
