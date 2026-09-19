# frozen_string_literal: true

require "stringio"
require "guardrails/tui/keys"

RSpec.describe Guardrails::TUI::Keys do
  def keys_for(bytes)
    reader = described_class.new(StringIO.new(bytes))
    events = []
    while (key = reader.next(timeout: 0))
      events << key
    end
    events
  end

  it "passes printable characters through as strings" do
    expect(keys_for("jq/")).to eq(["j", "q", "/"])
  end

  it "names the control keys" do
    expect(keys_for("\r\n\t\x7F\b\x03")).to eq(%i[enter enter tab backspace backspace ctrl_c])
  end

  it "decodes arrow keys in both CSI and application mode" do
    expect(keys_for("\e[A\e[B\e[C\e[D\eOA\eOB")).to eq(%i[up down right left up down])
  end

  it "decodes paging and home/end" do
    expect(keys_for("\e[5~\e[6~\e[H\e[F\e[1~\e[4~")).to eq(%i[page_up page_down home end home end])
  end

  it "reads a lone escape as :escape" do
    expect(keys_for("\e")).to eq([:escape])
  end

  it "separates a sequence from the keys typed right after it" do
    expect(keys_for("\e[Bj")).to eq([:down, "j"])
  end

  it "swallows unrecognized sequences whole rather than leaking their tail as text" do
    expect(keys_for("\e[15~")).to eq([:unknown])
  end

  it "keeps multi-byte characters intact" do
    expect(keys_for("é→")).to eq(["é", "→"])
  end

  it "ignores other control bytes" do
    expect(keys_for("\x01")).to eq([:unknown])
  end

  it "returns nil when there's no input" do
    expect(described_class.new(StringIO.new("")).next(timeout: 0)).to be_nil
  end

  it "reports :eof when a real input stream hangs up" do
    reader, writer = IO.pipe
    writer.close

    expect(described_class.new(reader).next(timeout: 0.1)).to eq(:eof)
  ensure
    reader&.close
  end
end
