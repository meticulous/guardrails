# frozen_string_literal: true

require "stringio"
require "guardrails/report/style"

RSpec.describe Guardrails::Report::Style do
  describe "#color?" do
    it "is false for a StringIO target (non-TTY)" do
      expect(described_class.new(io: StringIO.new).color?).to be false
    end

    it "is true when `force: true`" do
      expect(described_class.new(io: StringIO.new, force: true).color?).to be true
    end

    it "is false when `force: false` even on a TTY" do
      tty_like = double("tty", tty?: true)
      expect(described_class.new(io: tty_like, force: false).color?).to be false
    end

    it "is false when NO_COLOR env is set, even on a TTY" do
      tty_like = double("tty", tty?: true)
      expect(described_class.new(io: tty_like, no_color: true).color?).to be false
    end

    it "is true on a TTY when no NO_COLOR override is in play" do
      tty_like = double("tty", tty?: true)
      expect(described_class.new(io: tty_like, no_color: false).color?).to be true
    end
  end

  describe "#colorize" do
    it "wraps text in ANSI codes when color is on" do
      result = described_class.new(io: StringIO.new, force: true).colorize("hi", :red)
      expect(result).to eq("\e[31mhi\e[0m")
    end

    it "composes multiple style keys (bold + red)" do
      result = described_class.new(io: StringIO.new, force: true).colorize("hi", [:bold, :red])
      expect(result).to eq("\e[1m\e[31mhi\e[0m")
    end

    it "returns plain text when color is off" do
      result = described_class.new(io: StringIO.new, force: false).colorize("hi", :red)
      expect(result).to eq("hi")
    end

    it "raises for unknown style keys (loud failure beats silent miss)" do
      style = described_class.new(io: StringIO.new, force: true)
      expect { style.colorize("hi", :chartreuse) }.to raise_error(KeyError)
    end
  end

  describe "#severity" do
    let(:style) { described_class.new(io: StringIO.new, force: false) }

    it "prefixes the category with a padded severity tag" do
      expect(style.severity(:error, "raw_color")).to eq("[error]    raw_color")
    end

    it "uses [warning] for warnings" do
      expect(style.severity(:warning, "helper_recommended")).to eq("[warning]  helper_recommended")
    end

    it "uses [suggest] for suggestions" do
      expect(style.severity(:suggestion, "pattern")).to eq("[suggest]  pattern")
    end

    it "pads consistently across levels so columns line up" do
      lengths = %i[error warning suggestion].map { |lvl| style.severity(lvl, "x").index("x") }
      expect(lengths.uniq).to eq([lengths.first]) # all the same width
    end

    it "raises for unknown severity (catches typos in detector code)" do
      expect { style.severity(:catastrophic, "x") }.to raise_error(KeyError)
    end
  end

  describe "#section_heading" do
    it "formats a heading with glyph + level + dash + title" do
      style = described_class.new(io: StringIO.new, force: false)
      expect(style.section_heading(:error, "raw_color (82 findings)"))
        .to eq("x ERROR — raw_color (82 findings)")
    end
  end

  describe "#suggestion" do
    it "prefixes the action text with an arrow" do
      style = described_class.new(io: StringIO.new, force: false)
      expect(style.suggestion("replace with var(--token)")).to eq("→ replace with var(--token)")
    end
  end

  describe "#location" do
    it "returns the path plain when color is off" do
      style = described_class.new(io: StringIO.new, force: false)
      expect(style.location("app/views/foo.html.erb:42")).to eq("app/views/foo.html.erb:42")
    end

    it "dims the path when color is on" do
      style = described_class.new(io: StringIO.new, force: true)
      expect(style.location("app/views/foo.html.erb:42")).to include("\e[2m")
    end
  end

  describe "#box_chars" do
    it "returns light box-drawing characters when color is on" do
      chars = described_class.new(io: StringIO.new, force: true).box_chars
      expect(chars[:tl]).to eq("╭")
      expect(chars[:h]).to eq("─")
    end

    it "falls back to ASCII when color is off" do
      chars = described_class.new(io: StringIO.new, force: false).box_chars
      expect(chars[:tl]).to eq("+")
      expect(chars[:h]).to eq("-")
    end
  end
end
