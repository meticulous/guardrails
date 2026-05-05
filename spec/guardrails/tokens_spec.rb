# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/tokens"

RSpec.describe Guardrails::Tokens do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_file(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  def configure(colors_file: nil, type_scale_file: nil)
    yaml = +"guardrails:\n  tokens:\n"
    yaml << "    colors_file: #{colors_file}\n" if colors_file
    yaml << "    type_scale_file: #{type_scale_file}\n" if type_scale_file
    write_file "guardrails.yml", yaml
  end

  def parse
    described_class.new(root: root, output: StringIO.new).parse_tokens
  end

  describe "#parse_tokens" do
    it "returns an empty list when no colors_file is configured" do
      expect(parse).to be_empty
    end

    it "returns an empty list when the configured file doesn't exist" do
      configure(colors_file: "missing.scss")
      expect(parse).to be_empty
    end

    it "parses SCSS variable definitions" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", <<~SCSS
        $primary: #0066ff;
        $secondary: #ffaa33;
      SCSS

      tokens = parse
      expect(tokens.length).to eq(2)
      expect(tokens.first.name).to eq("primary")
      expect(tokens.first.value).to eq("#0066ff")
      expect(tokens.first.syntax).to eq(:scss_var)
    end

    it "parses CSS custom property definitions" do
      configure(colors_file: "tokens.css")
      write_file "tokens.css", <<~CSS
        :root {
          --primary-500: #0066ff;
          --secondary-500: #ffaa33;
        }
      CSS

      tokens = parse
      expect(tokens.length).to eq(2)
      expect(tokens.map(&:name)).to contain_exactly("primary-500", "secondary-500")
      expect(tokens.first.syntax).to eq(:css_var)
    end

    it "parses Tailwind v4 @theme blocks (CSS custom properties)" do
      configure(colors_file: "tokens.css")
      write_file "tokens.css", <<~CSS
        @theme {
          --color-primary: #0066ff;
        }
      CSS

      tokens = parse
      expect(tokens.length).to eq(1)
      expect(tokens.first.name).to eq("color-primary")
    end

    it "captures the line where each token is defined" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", <<~SCSS
        // Brand colors
        $primary: #0066ff;
        $secondary: #ffaa33;
      SCSS

      tokens = parse
      expect(tokens[0].line).to eq(2)
      expect(tokens[1].line).to eq(3)
    end

    it "parses both CSS vars and SCSS vars when both are present" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", <<~SCSS
        $primary: #0066ff;
        :root { --secondary: #ffaa33; }
      SCSS

      tokens = parse
      syntaxes = tokens.map(&:syntax)
      expect(syntaxes).to include(:scss_var, :css_var)
    end

    it "parses tokens from type_scale_file when configured" do
      configure(colors_file: "colors.css", type_scale_file: "type.css")
      write_file "colors.css", ":root { --primary: #0066ff; }\n"
      write_file "type.css", ":root { --text-base: 1rem; --text-lg: 1.25rem; }\n"

      tokens = parse
      names = tokens.map(&:name)
      expect(names).to include("primary", "text-base", "text-lg")
    end

    it "parses type_scale_file even when colors_file is not configured" do
      configure(type_scale_file: "type.css")
      write_file "type.css", ":root { --text-base: 1rem; }\n"

      expect(parse.map(&:name)).to eq(["text-base"])
    end

    it "auto-discovers tokens from tailwind.config.js at the repo root" do
      write_file "tailwind.config.js", <<~JS
        module.exports = {
          theme: {
            extend: {
              colors: { primary: "#0066ff", accent: "#ffaa33" }
            }
          }
        }
      JS

      tokens = parse
      tailwind = tokens.select { |t| t.syntax == :tailwind }
      expect(tailwind.map(&:name)).to contain_exactly("primary", "accent")
    end

    it "combines tokens from colors_file and tailwind.config.js" do
      configure(colors_file: "tokens.css")
      write_file "tokens.css", ":root { --neutral-100: #f5f5f5; }\n"
      write_file "tailwind.config.js", <<~JS
        module.exports = { theme: { colors: { primary: "#0066ff" } } }
      JS

      names = parse.map(&:name)
      expect(names).to include("neutral-100", "primary")
    end
  end

  describe "#detect_drift" do
    def detect
      audit = described_class.new(root: root, output: StringIO.new)
      audit.detect_drift(audit.parse_tokens)
    end

    it "returns no drift when stylesheets only use defined token references" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"
      write_file "app/assets/stylesheets/_button.scss", ".btn { color: $primary; }"

      expect(detect).to be_empty
    end

    it "flags hex literals in non-token stylesheets" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"
      write_file "app/assets/stylesheets/_button.scss", ".btn { color: #0066ff; }"

      drift = detect
      expect(drift.length).to eq(1)
      expect(drift.first.value).to eq("#0066ff")
    end

    it "matches drift values to defined tokens" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"
      write_file "app/assets/stylesheets/_button.scss", ".btn { color: #0066ff; }"

      expect(detect.first.matched_token.name).to eq("primary")
    end

    it "matches normalized hex (case + short form expansion)" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$brand: #FFAA33;"
      write_file "app/assets/stylesheets/_x.scss", ".x { color: #fa3; }"

      drift = detect
      expect(drift.first.matched_token.name).to eq("brand")
    end

    it "reports unmatched drift with no matched_token" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"
      write_file "app/assets/stylesheets/_x.scss", ".x { color: #abcdef; }"

      drift = detect
      expect(drift.first.matched_token).to be_nil
    end

    it "skips the configured colors_file itself" do
      configure(colors_file: "app/assets/stylesheets/_tokens.scss")
      write_file "app/assets/stylesheets/_tokens.scss", "$primary: #0066ff;"

      expect(detect).to be_empty
    end

    it "skips lines that look like token definitions" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"
      write_file "app/assets/stylesheets/_more-tokens.scss", "$another: #abcdef;"

      expect(detect).to be_empty
    end

    it "matches stylesheet drift against tailwind.config.js theme colors" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$other: #abcdef;"
      write_file "tailwind.config.js", <<~JS
        module.exports = { theme: { colors: { brand: "#0066ff" } } }
      JS
      write_file "app/assets/stylesheets/_button.scss", ".btn { color: #0066ff; }"

      drift = detect
      expect(drift.length).to eq(1)
      expect(drift.first.matched_token.name).to eq("brand")
      expect(drift.first.matched_token.syntax).to eq(:tailwind)
    end

    it "ignores hex literals inside line comments" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"
      write_file "app/assets/stylesheets/_button.scss", <<~SCSS
        // Brand color is #0066ff but we use the token below
        .btn { color: $primary; }
      SCSS

      expect(detect).to be_empty
    end

    it "ignores hex literals inside block comments" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"
      write_file "app/assets/stylesheets/_button.scss", <<~SCSS
        /* Old palette: #0066ff and #ffaa33 */
        .btn { color: $primary; }
      SCSS

      expect(detect).to be_empty
    end

    it "still flags drift on the same line as a comment when the hex is in code" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"
      write_file "app/assets/stylesheets/_button.scss", <<~SCSS
        .btn { color: #ffaa33; /* wrong, should be primary */ }
      SCSS

      expect(detect.length).to eq(1)
      expect(detect.first.value).to eq("#ffaa33")
    end
  end

  describe "#run" do
    it "reports a friendly message when no token files are configured" do
      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("no colors_file, type_scale_file, or tailwind.config.js")
    end

    it "names tailwind.config.js as a recognized source when it's the only one" do
      write_file "tailwind.config.js", <<~JS
        module.exports = { theme: { colors: { primary: "#0066ff" } } }
      JS

      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("tailwind.config.js")
      expect(output.string).not_to include("no colors_file")
    end

    it "labels tailwind tokens distinctly in the per-token list" do
      write_file "tailwind.config.js", <<~JS
        module.exports = { theme: { colors: { primary: "#0066ff" } } }
      JS

      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("Tailwind theme color `primary`")
      expect(output.string).not_to match(/^\s*\$primary =/)
    end

    it "reports the token count and contents" do
      configure(colors_file: "tokens.scss")
      write_file "tokens.scss", "$primary: #0066ff;"

      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("1 token found")
      expect(output.string).to include("$primary = #0066ff")
    end
  end
end
