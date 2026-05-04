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

  def configure(colors_file:)
    write_file "guardrails.yml", <<~YAML
      guardrails:
        tokens:
          colors_file: #{colors_file}
    YAML
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
  end

  describe "#run" do
    it "reports a friendly message when no colors_file is configured" do
      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("no colors_file configured")
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
