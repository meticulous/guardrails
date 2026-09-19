# frozen_string_literal: true

require "guardrails/tui/state"

RSpec.describe Guardrails::TUI::State do
  def finding(category, severity, title, locations: [], suggestion: nil, auto_fix: false)
    Guardrails::Report::Finding.new(
      category: category, severity: severity, title: title, suggestion: suggestion, auto_fix: auto_fix,
      locations: locations.map { |file, line| Guardrails::Report::Location.new(file: file, line: line) }
    )
  end

  def category(name, severity, findings, auto_fix: false)
    Guardrails::Report::Category.new(name: name, severity: severity, framing: "About #{name}.",
                                     findings: findings, auto_fix: auto_fix)
  end

  let(:categories) do
    [
      category("raw_color", :error, [
        finding("raw_color", :error, "raw_color: #0066ff", locations: [["app/views/home.html.erb", 7]],
                                                           suggestion: "replace with var(--primary)", auto_fix: true),
        finding("raw_color", :error, "raw_color: #abcdef", locations: [["app/views/about.html.erb", 3]], auto_fix: true)
      ], auto_fix: true),
      category("inline_style", :warning, [
        finding("inline_style", :warning, "inline_style: color: red", locations: [["app/views/home.html.erb", 4]])
      ]),
      category("class-itis", :suggestion, [
        finding("class-itis", :suggestion, "<div> with 9 classes",
                locations: [["app/views/home.html.erb", 12], ["app/views/about.html.erb", 9]])
      ]),
      category("a11y (deep)", :error, [finding("a11y (deep)", :error, "[serious] color-contrast")])
    ]
  end

  subject(:state) { described_class.new(categories: categories) }

  def press(*keys)
    keys.map { |key| state.handle(key) }.last
  end

  describe "the rollup" do
    it "groups categories under severity headers, errors first" do
      expect(state.rows.map { |r| [r.kind, r.severity] }).to eq(
        [[:header, :error], [:item, :error], [:item, :error],
         [:header, :warning], [:item, :warning],
         [:header, :suggestion], [:item, :suggestion]]
      )
    end

    it "orders categories within a severity by finding count" do
      expect(state.rows.select(&:selectable?).first(2).map(&:label)).to eq(["raw_color", "a11y (deep)"])
    end

    it "starts the cursor on the first category, not the header above it" do
      expect(state.selected_row.label).to eq("raw_color")
    end

    it "flags auto-fixable categories" do
      expect(state.selected_row.flag).to eq("auto-fix")
    end
  end

  describe "moving" do
    it "skips header rows" do
      press(:down, :down)

      expect(state.selected_row.label).to eq("inline_style")
    end

    it "accepts vi keys" do
      press("j")
      expect(state.selected_row.label).to eq("a11y (deep)")
      press("k")
      expect(state.selected_row.label).to eq("raw_color")
    end

    it "stops at both ends" do
      press(:up)
      expect(state.selected_row.label).to eq("raw_color")
      press("G", :down)
      expect(state.selected_row.label).to eq("class-itis")
      press("g")
      expect(state.selected_row.label).to eq("raw_color")
    end

    it "pages by page_size" do
      state.page_size = 2
      press(:page_down)

      expect(state.selected_row.label).to eq("inline_style")
    end
  end

  describe "drilling in" do
    it "goes rollup → findings → detail and back out" do
      press(:enter)
      expect(state.frame.kind).to eq(:findings)
      expect(state.rows.map(&:label)).to eq(["raw_color: #0066ff", "raw_color: #abcdef"])

      press(:enter)
      expect(state.frame.kind).to eq(:detail)
      expect(state.selected_finding.title).to eq("raw_color: #0066ff")
      expect(state.breadcrumb).to eq(["All findings", "raw_color", "raw_color: #0066ff"])

      press(:escape, :escape)
      expect(state.frame.kind).to eq(:rollup)
    end

    it "remembers the cursor of the screen it came back to" do
      press(:down, :enter, :escape)

      expect(state.selected_row.label).to eq("a11y (deep)")
    end

    it "lists every location of a multi-location finding on its detail screen" do
      press("G", :enter, :enter)

      expect(state.rows.map(&:label)).to eq(["app/views/home.html.erb:12", "app/views/about.html.erb:9"])
    end
  end

  describe "opening an editor" do
    it "returns an edit action for the highlighted finding's location" do
      press(:enter)

      expect(press("o")).to eq([:edit, categories.first.findings.first.location])
    end

    it "opens the selected location from a detail screen with enter" do
      press("G", :enter, :enter, :down)
      action, location = press(:enter)

      expect(action).to eq(:edit)
      expect(location.to_s).to eq("app/views/about.html.erb:9")
    end

    it "explains itself instead when a finding has no file location" do
      press(:down, :enter)

      expect(press("o")).to be_nil
      expect(state.notice).to include("no file location")
    end

    it "clears the notice on the next key" do
      press(:down, :enter, "o", :down)

      expect(state.notice).to be_nil
    end
  end

  describe "grouping by file" do
    before { press(:tab) }

    it "ranks files by finding count, counting multi-file findings in each" do
      expect(state.rows.map { |r| [r.label, r.meta] }).to eq(
        [["app/views/home.html.erb", "3 findings"], ["app/views/about.html.erb", "2 findings"], ["(no file)", "1 finding"]]
      )
    end

    it "gives each file its worst severity" do
      expect(state.rows.map(&:severity)).to eq(%i[error error error])
    end

    it "lists a file's findings with their category and line" do
      press(:enter)

      expect(state.rows.map(&:meta)).to eq(["raw_color · line 7", "inline_style · line 4", "class-itis · line 12"])
    end

    it "opens a multi-file finding at its occurrence in the file being browsed" do
      press(:down, :enter, :down)
      _, location = press("o")

      expect(location.to_s).to eq("app/views/about.html.erb:9")
    end

    it "opens the file itself from the file list" do
      _, location = press("o")

      expect(location.to_s).to eq("app/views/home.html.erb")
    end

    it "toggles back to categories" do
      press(:tab)

      expect(state.frame.kind).to eq(:rollup)
    end
  end

  describe "filtering" do
    it "narrows findings live as you type, across title, category, suggestion, and file" do
      press("/", *"about".chars)

      expect(state).to be_filtering
      expect(state.visible_findings.map(&:title)).to eq(["raw_color: #abcdef", "<div> with 9 classes"])
      expect(state.totals).to eq(error: 1, warning: 0, suggestion: 1)
    end

    it "is case-insensitive and matches suggestions" do
      press("/", *"VAR(--".chars)

      expect(state.visible_findings.map(&:title)).to eq(["raw_color: #0066ff"])
    end

    it "treats navigation letters as text while typing" do
      press("/", "q", "j")

      expect(state.filter).to eq("qj")
    end

    it "keeps the filter on enter, and hides categories left empty" do
      press("/", *"about".chars, :enter)

      expect(state).not_to be_filtering
      expect(state.rows.select(&:selectable?).map(&:label)).to eq(["raw_color", "class-itis"])
    end

    it "clears on escape" do
      press("/", "x", :escape)

      expect(state.filter).to eq("")
      expect(state).not_to be_filtering
    end

    it "clears from the top level with escape after being kept" do
      press("/", *"about".chars, :enter, :escape)

      expect(state.filter).to eq("")
    end

    it "edits with backspace, and leaves filter mode when there's nothing left to delete" do
      press("/", "a", "b", :backspace)
      expect(state.filter).to eq("a")

      press(:backspace, :backspace)
      expect(state).not_to be_filtering
    end

    it "leaves no selection when nothing matches" do
      press("/", *"zzz".chars)

      expect(state.rows).to be_empty
      expect(state.selected_row).to be_nil
      expect(press(:enter, :down, :enter)).to be_nil
    end
  end

  describe "actions" do
    it "asks the loop to quit on q and ctrl-c" do
      expect(press("q")).to eq([:quit])
      expect(press(:ctrl_c)).to eq([:quit])
    end

    it "asks for the web report and a re-run" do
      expect(press("w")).to eq([:web])
      expect(press("r")).to eq([:rerun])
    end

    it "shows help until the next key, which it swallows" do
      press("?")
      expect(state).to be_help

      expect(press("q")).to be_nil
      expect(state).not_to be_help
    end
  end

  describe "#replace" do
    it "swaps in new results, keeping grouping and filter but not the drill-down" do
      press(:tab, "/", *"home".chars, :enter, :enter)
      state.replace(categories: categories.first(1))

      expect(state.frame.kind).to eq(:files)
      expect(state.filter).to eq("home")
      expect(state.rows.map(&:label)).to eq(["app/views/home.html.erb"])
    end
  end

  it "handles an audit with no findings" do
    empty = described_class.new(categories: [])

    expect(empty.rows).to be_empty
    expect(empty.handle(:enter)).to be_nil
    expect(empty.handle(:down)).to be_nil
    expect(empty.totals.values.sum).to eq(0)
  end
end
