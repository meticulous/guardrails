# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/audit"
require "guardrails/audit/markdown_writer"
require "guardrails/tokens"

RSpec.describe Guardrails::Audit::MarkdownWriter do
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:now) { Time.utc(2026, 5, 4, 16, 30, 0) }
  after { FileUtils.rm_rf(root) }

  def violation(type:, file:, line: 1, column: 1, snippet: "x", value: nil)
    Guardrails::Audit::Violation.new(
      type: type, file: file, line: line, column: column, snippet: snippet, value: value
    )
  end

  describe "#write" do
    it "writes to doc/guardrails-suggestions-{TS}.md" do
      described_class.new(root, output: StringIO.new, now: now).write([])

      expect(root.join("doc/guardrails-suggestions-20260504T163000Z.md")).to exist
    end

    it "creates the doc directory if it doesn't exist" do
      expect(root.join("doc")).not_to exist
      described_class.new(root, output: StringIO.new, now: now).write([])
      expect(root.join("doc")).to exist
    end

    it "writes a header with totals" do
      v = violation(type: :inline_style, file: "app/views/x.html.erb")
      described_class.new(root, output: StringIO.new, now: now).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("# Guardrails audit — suggestions")
      expect(content).to include("Total violations:** 1")
      expect(content).to include("Files touched:** 1")
    end

    it "writes a friendly message when there are no violations" do
      described_class.new(root, output: StringIO.new, now: now).write([])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("No violations to suggest fixes for")
    end

    it "groups violations by file then by type" do
      vs = [
        violation(type: :inline_style, file: "app/views/a.html.erb", line: 1),
        violation(type: :raw_color, file: "app/views/a.html.erb", line: 2),
        violation(type: :tailwind_arbitrary, file: "app/views/b.html.erb", line: 5)
      ]
      described_class.new(root, output: StringIO.new, now: now).write(vs)

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to match(/## app\/views\/a\.html\.erb.+### inline_style.+### raw_color.+## app\/views\/b\.html\.erb.+### tailwind_arbitrary/m)
    end

    it "renders each violation as a checkbox item" do
      v = violation(
        type: :tailwind_arbitrary,
        file: "app/views/x.html.erb",
        line: 7,
        column: 12,
        snippet: '<div class="bg-[#fa3]">x</div>'
      )
      described_class.new(root, output: StringIO.new, now: now).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("- [ ] **Line 7, col 12:** `<div class=\"bg-[#fa3]\">x</div>`")
      expect(content).to include("**Rule:**")
      expect(content).to include("**Suggested replacement:**")
    end

    it "returns the path to the written file" do
      result = described_class.new(root, output: StringIO.new, now: now).write([])
      expect(result).to eq(root.join("doc/guardrails-suggestions-20260504T163000Z.md"))
    end

    it "logs the relative path to the output stream" do
      output = StringIO.new
      described_class.new(root, output: output, now: now).write([])
      expect(output.string).to include("doc/guardrails-suggestions-20260504T163000Z.md")
    end
  end

  describe "token-aware suggestions" do
    def token(name:, value:, syntax: :scss_var, file: "tokens.scss", line: 1)
      Guardrails::Tokens::Token.new(
        name: name, value: value, syntax: syntax, file: file, line: line
      )
    end

    it "suggests the matching token reference for raw_color when an exact match exists" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#0066ff",
                    snippet: '<svg fill="#0066ff"></svg>')
      tokens = [token(name: "primary", value: "#0066ff", syntax: :css_var)]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("Use `var(--primary)`")
      expect(content).to include("matches token `primary`")
    end

    it "does NOT suggest scss_var tokens for raw_color violations (they don't compile in HTML attrs)" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#0066ff",
                    snippet: '<svg fill="#0066ff"></svg>')
      tokens = [token(name: "primary", value: "#0066ff", syntax: :scss_var)]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).not_to include("$primary")
      expect(content).to include("Use a CSS custom property") # falls back to stock
    end

    it "suggests var(--name) for CSS custom property tokens" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#0066ff",
                    snippet: '<svg fill="#0066ff"></svg>')
      tokens = [token(name: "primary-500", value: "#0066ff", syntax: :css_var)]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("Use `var(--primary-500)`")
    end

    it "matches normalized hex (case + short form)" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#fa3",
                    snippet: '<svg fill="#fa3"></svg>')
      tokens = [token(name: "secondary", value: "#FFAA33", syntax: :css_var)]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("matches token `secondary`")
    end

    it "suggests a Tailwind utility name for tailwind_arbitrary violations" do
      v = violation(type: :tailwind_arbitrary, file: "app/views/x.html.erb", value: "#0066ff",
                    snippet: '<div class="bg-[#0066ff]">x</div>')
      tokens = [token(name: "primary", value: "#0066ff", syntax: :tailwind)]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("Use `bg-primary`")
      expect(content).to include("matches token `primary`")
    end

    it "prefers a Tailwind utility over a parameterized arbitrary when both are available" do
      v = violation(type: :tailwind_arbitrary, file: "app/views/x.html.erb", value: "#0066ff",
                    snippet: '<div class="bg-[#0066ff]">x</div>')
      tokens = [
        token(name: "primary", value: "#0066ff", syntax: :css_var),
        token(name: "primary", value: "#0066ff", syntax: :tailwind)
      ]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("Use `bg-primary`")
      expect(content).not_to include("var(--primary)")
    end

    it "matches type-scale values like 1rem to a defined size token (css_var fallback)" do
      v = violation(type: :tailwind_arbitrary, file: "app/views/x.html.erb", value: "1rem",
                    snippet: '<div class="text-[1rem]">x</div>')
      tokens = [token(name: "text-base", value: "1rem", syntax: :css_var)]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("matches token `text-base`")
      expect(content).to include("var(--text-base)")
    end

    it "falls back to the stock suggestion when no token matches" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#abcdef",
                    snippet: '<svg fill="#abcdef"></svg>')
      tokens = [token(name: "primary", value: "#0066ff")]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("Use a CSS custom property or SCSS variable")
      expect(content).not_to include("matches token")
    end

    it "uses stock suggestions when no tokens are provided" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#0066ff",
                    snippet: '<svg fill="#0066ff"></svg>')

      described_class.new(root, output: StringIO.new, now: now).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("Use a CSS custom property or SCSS variable")
    end
  end

  describe "helper_recommended suggestion text" do
    it "renders an element-specific Rails-helper recommendation for button" do
      v = violation(type: :helper_recommended, file: "app/views/x.html.erb",
                    value: "button", snippet: "<button><%= label %></button>")

      described_class.new(root, output: StringIO.new, now: now).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("`tag.button(label, ...)`")
      expect(content).to include("`button_to(label, path)`")
    end

    it "renders link_to suggestion for a tags" do
      v = violation(type: :helper_recommended, file: "app/views/x.html.erb",
                    value: "a", snippet: '<a href="/x"><%= label %></a>')

      described_class.new(root, output: StringIO.new, now: now).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("`link_to(label, path, ...)`")
    end
  end

  describe "near-match suggestions" do
    def token(name:, value:, syntax: :css_var)
      Guardrails::Tokens::Token.new(
        name: name, value: value, syntax: syntax, file: "tokens.css", line: 1
      )
    end

    it "shows near-match suggestions under the default 'notify' policy" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#0066fe",
                    snippet: '<svg fill="#0066fe"></svg>')
      tokens = [token(name: "primary", value: "#0066ff")]

      described_class.new(root, output: StringIO.new, now: now, tokens: tokens).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("near match")
      expect(content).to include("close to token `primary`")
    end

    it "hides near-match suggestions under 'leave' policy (falls back to stock)" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#0066fe",
                    snippet: '<svg fill="#0066fe"></svg>')
      tokens = [token(name: "primary", value: "#0066ff")]

      described_class.new(
        root, output: StringIO.new, now: now, tokens: tokens, near_match_policy: "leave"
      ).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).not_to include("near match")
      expect(content).not_to include("close to token")
      expect(content).to include("Use a CSS custom property or SCSS variable")
    end

    it "shows exact matches regardless of policy" do
      v = violation(type: :raw_color, file: "app/views/x.html.erb", value: "#0066ff",
                    snippet: '<svg fill="#0066ff"></svg>')
      tokens = [token(name: "primary", value: "#0066ff")]

      described_class.new(
        root, output: StringIO.new, now: now, tokens: tokens, near_match_policy: "leave"
      ).write([v])

      content = root.join("doc/guardrails-suggestions-20260504T163000Z.md").read(encoding: Encoding::UTF_8)
      expect(content).to include("matches token `primary`")
    end
  end
end
