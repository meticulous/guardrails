# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "guardrails/report/run"
require "guardrails/tui/state"
require "guardrails/tui/screen"

RSpec.describe Guardrails::TUI::Screen do
  let(:root) { Pathname(File.expand_path("../../../examples/demo", __dir__)) }
  let(:state) { Guardrails::TUI::State.new(categories: Guardrails::Report::Run.new(root: root).call.categories) }

  def render(width: 100, height: 30, color: false, root_dir: root)
    described_class.new(state: state, root: root_dir, width: width, height: height, color: color).lines
  end

  def plain(lines)
    lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }
  end

  def press(*keys)
    keys.each { |key| state.handle(key) }
  end

  it "always fills the terminal exactly, never overflowing its width" do
    [[100, 30], [80, 24], [60, 12], [40, 10], [200, 60]].each do |width, height|
      [[], [:enter], %i[enter enter], [:tab], %i[tab enter], ["?"], ["/", "h"]].each do |keys|
        fresh = Guardrails::TUI::State.new(categories: state.instance_variable_get(:@categories))
        keys.each { |key| fresh.handle(key) }
        lines = plain(described_class.new(state: fresh, root: root, width: width, height: height, color: true).lines)

        expect(lines.length).to eq(height), "#{width}x#{height} after #{keys.inspect}"
        expect(lines.map(&:length).max).to be <= width, "#{width}x#{height} after #{keys.inspect}"
      end
    end
  end

  it "shows totals by severity and the grouping in the title bar" do
    title = plain(render).first

    expect(title).to include("20 findings", "x 8", "! 10", "i 2")
    expect(title).to end_with("by category")
  end

  it "renders the rollup with severity headers and a position counter" do
    screen = plain(render).join("\n")

    expect(screen).to include("x ERROR — 3 categories, 8 findings", "› x raw_color", "[auto-fix]", "1/10")
  end

  it "previews source around the highlighted finding, marking its line" do
    press(:enter)
    screen = plain(render)

    expect(screen).to include(a_string_matching(/▸\s+7 │ <svg fill="#0066ff"/))
    expect(screen).to include(a_string_including("→ replace with var(--primary-500)"))
  end

  it "drops the preview when the terminal is too short to give it context" do
    press(:enter)

    expect(plain(render(height: 12)).join).not_to include("│")
  end

  it "shows the suggestion, framing, and locations on a detail screen" do
    press(:enter, :enter)
    screen = plain(render).join("\n")

    expect(screen).to include("[error]", "raw_color: #0066ff", "→ replace with var(--primary-500)",
                              "Hex/rgb literals in color attributes", "1 location")
  end

  it "scrolls to keep the cursor visible" do
    press(:tab, "G")
    screen = plain(render(height: 10)).join("\n")

    expect(screen).to include("› ! app/javascript/controllers/dead_controller.js", "8/8")
    expect(screen).not_to include("broken.html.erb")
  end

  it "shows the filter prompt while typing and the active filter after" do
    press("/", "h", "e", "r", "o")
    expect(plain(render).last).to include("/ hero█")

    press(:enter)
    expect(plain(render).first).to include("filter: hero")
  end

  it "says so when a filter matches nothing" do
    press("/", "z", "z", "z", :enter)

    expect(plain(render).join("\n")).to include("No findings match “zzz”")
  end

  it "celebrates a clean audit" do
    clean = described_class.new(state: Guardrails::TUI::State.new(categories: []), root: root, width: 80, height: 20, color: false)

    expect(plain(clean.lines).join("\n")).to include("No findings — the audit is clean.")
  end

  it "shows notices in place of the key hints" do
    state.notice = "Opened tmp/guardrails/audit.html"

    expect(plain(render).last).to include("Opened tmp/guardrails/audit.html")
  end

  it "uses color only when asked, but keeps the selection visible either way" do
    expect(render(color: true).join).to include("\e[1;31m")

    uncolored = render(color: false).join
    expect(uncolored).not_to match(/\e\[[\d;]*3[0-9]m/)
    expect(uncolored).to include("\e[7;1m")
  end

  it "neutralizes terminal escape sequences in previewed source and titles" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/views"))
      File.write(File.join(dir, "app/views/evil.html.erb"), "<p>\e[2J\e[31mgotcha\a</p>\n")
      finding = Guardrails::Report::Finding.new(
        category: "inline_style", severity: :warning, title: "inline_style: \e[2Jboom",
        locations: [Guardrails::Report::Location.new(file: "app/views/evil.html.erb", line: 1)]
      )
      evil = Guardrails::TUI::State.new(categories: [
        Guardrails::Report::Category.new(name: "inline_style", severity: :warning, findings: [finding])
      ])
      evil.handle(:enter)
      lines = described_class.new(state: evil, root: dir, width: 80, height: 24, color: false).lines

      expect(lines.join).not_to include("\e[2J", "\e[31m", "\a")
      expect(plain(lines).join("\n")).to include("gotcha")
    end
  end

  it "explains why a location can't be previewed" do
    finding = Guardrails::Report::Finding.new(
      category: "visual diff", severity: :error, title: "[diff present] checkout",
      locations: [Guardrails::Report::Location.new(file: "doc/gone.png")]
    )
    missing = Guardrails::TUI::State.new(categories: [
      Guardrails::Report::Category.new(name: "visual diff", severity: :error, findings: [finding])
    ])
    missing.handle(:enter)
    lines = described_class.new(state: missing, root: root, width: 80, height: 24, color: false).lines

    expect(plain(lines).join("\n")).to include("(file not found)")
  end
end
