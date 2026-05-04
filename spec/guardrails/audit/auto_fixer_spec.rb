# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/audit"
require "guardrails/audit/auto_fixer"
require "guardrails/tokens"

RSpec.describe Guardrails::Audit::AutoFixer do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_view(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  def view_content(relative)
    root.join(relative).read(encoding: Encoding::UTF_8)
  end

  def violation(type:, file:, line:, column:, value:, snippet: "")
    Guardrails::Audit::Violation.new(
      type: type, file: file, line: line, column: column, snippet: snippet, value: value
    )
  end

  def token(name:, value:, syntax: :css_var)
    Guardrails::Tokens::Token.new(
      name: name, value: value, syntax: syntax,
      file: "tokens.css", line: 1
    )
  end

  describe "#apply" do
    it "rewrites a raw_color hex with var(--token) when an exact CSS-var match exists" do
      write_view "app/views/x.html.erb", '<svg fill="#0066ff"></svg>'
      v = violation(type: :raw_color, file: "app/views/x.html.erb", line: 1, column: 12, value: "#0066ff")
      tokens = [token(name: "primary-500", value: "#0066ff")]

      described_class.new(root, output: StringIO.new, tokens: tokens).apply([v])

      expect(view_content("app/views/x.html.erb")).to eq('<svg fill="var(--primary-500)"></svg>')
    end

    it "matches normalized hex (case + short form)" do
      write_view "app/views/x.html.erb", '<svg fill="#fa3"></svg>'
      v = violation(type: :raw_color, file: "app/views/x.html.erb", line: 1, column: 12, value: "#fa3")
      tokens = [token(name: "secondary", value: "#FFAA33")]

      described_class.new(root, output: StringIO.new, tokens: tokens).apply([v])

      expect(view_content("app/views/x.html.erb")).to include("var(--secondary)")
    end

    it "applies multiple replacements on the same line right-to-left" do
      write_view "app/views/x.html.erb", '<svg fill="#0066ff" stroke="#fa3"></svg>'
      vs = [
        violation(type: :raw_color, file: "app/views/x.html.erb", line: 1, column: 12, value: "#0066ff"),
        violation(type: :raw_color, file: "app/views/x.html.erb", line: 1, column: 29, value: "#fa3")
      ]
      tokens = [
        token(name: "primary", value: "#0066ff"),
        token(name: "secondary", value: "#fa3")
      ]

      described_class.new(root, output: StringIO.new, tokens: tokens).apply(vs)

      content = view_content("app/views/x.html.erb")
      expect(content).to include("var(--primary)")
      expect(content).to include("var(--secondary)")
    end

    it "does not apply for SCSS variable tokens (not valid in views)" do
      write_view "app/views/x.html.erb", '<svg fill="#0066ff"></svg>'
      v = violation(type: :raw_color, file: "app/views/x.html.erb", line: 1, column: 12, value: "#0066ff")
      tokens = [token(name: "primary", value: "#0066ff", syntax: :scss_var)]

      result = described_class.new(root, output: StringIO.new, tokens: tokens).apply([v])

      expect(result).to be_empty
      expect(view_content("app/views/x.html.erb")).to eq('<svg fill="#0066ff"></svg>')
    end

    it "does not apply when no token matches" do
      write_view "app/views/x.html.erb", '<svg fill="#abcdef"></svg>'
      v = violation(type: :raw_color, file: "app/views/x.html.erb", line: 1, column: 12, value: "#abcdef")
      tokens = [token(name: "primary", value: "#0066ff")]

      result = described_class.new(root, output: StringIO.new, tokens: tokens).apply([v])

      expect(result).to be_empty
      expect(view_content("app/views/x.html.erb")).to eq('<svg fill="#abcdef"></svg>')
    end

    it "skips inline_style violations" do
      v = violation(type: :inline_style, file: "app/views/x.html.erb", line: 1, column: 1, value: 'style="color: red"')
      tokens = [token(name: "primary", value: "#0066ff")]

      fixer = described_class.new(root, output: StringIO.new, tokens: tokens)
      expect(fixer.applicable?(v)).to be(false)
    end

    it "skips tailwind_arbitrary violations" do
      v = violation(type: :tailwind_arbitrary, file: "app/views/x.html.erb", line: 1, column: 1, value: "#0066ff")
      tokens = [token(name: "primary", value: "#0066ff")]

      fixer = described_class.new(root, output: StringIO.new, tokens: tokens)
      expect(fixer.applicable?(v)).to be(false)
    end

    it "verifies the value is at the expected column before replacing" do
      write_view "app/views/x.html.erb", "<p>different content</p>"
      v = violation(type: :raw_color, file: "app/views/x.html.erb", line: 1, column: 12, value: "#0066ff")
      tokens = [token(name: "primary", value: "#0066ff")]

      result = described_class.new(root, output: StringIO.new, tokens: tokens).apply([v])

      expect(result).to be_empty
      expect(view_content("app/views/x.html.erb")).to eq("<p>different content</p>")
    end

    it "returns Result entries with the violation, token, and replacement string" do
      write_view "app/views/x.html.erb", '<svg fill="#0066ff"></svg>'
      v = violation(type: :raw_color, file: "app/views/x.html.erb", line: 1, column: 12, value: "#0066ff")
      tokens = [token(name: "primary-500", value: "#0066ff")]

      result = described_class.new(root, output: StringIO.new, tokens: tokens).apply([v])

      expect(result.length).to eq(1)
      expect(result.first.token.name).to eq("primary-500")
      expect(result.first.replacement).to eq("var(--primary-500)")
    end

    it "applies fixes across multiple files" do
      write_view "app/views/a.html.erb", '<svg fill="#0066ff"></svg>'
      write_view "app/views/b.html.erb", '<svg fill="#0066ff"></svg>'
      vs = [
        violation(type: :raw_color, file: "app/views/a.html.erb", line: 1, column: 12, value: "#0066ff"),
        violation(type: :raw_color, file: "app/views/b.html.erb", line: 1, column: 12, value: "#0066ff")
      ]
      tokens = [token(name: "primary", value: "#0066ff")]

      described_class.new(root, output: StringIO.new, tokens: tokens).apply(vs)

      expect(view_content("app/views/a.html.erb")).to include("var(--primary)")
      expect(view_content("app/views/b.html.erb")).to include("var(--primary)")
    end
  end
end
