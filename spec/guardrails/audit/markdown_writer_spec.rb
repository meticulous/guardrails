# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/audit"
require "guardrails/audit/markdown_writer"

RSpec.describe Guardrails::Audit::MarkdownWriter do
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:now) { Time.utc(2026, 5, 4, 16, 30, 0) }
  after { FileUtils.rm_rf(root) }

  def violation(type:, file:, line: 1, column: 1, snippet: "x")
    Guardrails::Audit::Violation.new(
      type: type, file: file, line: line, column: column, snippet: snippet
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
end
