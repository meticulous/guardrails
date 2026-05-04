# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "guardrails/init/stack_detector"

RSpec.describe Guardrails::Init::StackDetector do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_stylesheet(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  describe "#detect" do
    it "returns :none when no stylesheets exist" do
      result = described_class.new(root).detect

      expect(result.strategy).to eq(:none)
      expect(result.stylesheets).to be_empty
      expect(result.evidence[:files_scanned]).to eq(0)
    end

    it "detects CSS custom properties" do
      write_stylesheet "app/assets/stylesheets/tokens.css", <<~CSS
        :root {
          --primary-500: #0066ff;
          --type-base: 1rem;
        }
      CSS

      expect(described_class.new(root).detect.strategy).to eq(:css_custom_properties)
    end

    it "detects SCSS variables" do
      write_stylesheet "app/assets/stylesheets/_tokens.scss", <<~SCSS
        $primary: #0066ff;
        $type-base: 1rem;
      SCSS

      expect(described_class.new(root).detect.strategy).to eq(:scss_variables)
    end

    it "flags raw hex when no token system is present" do
      write_stylesheet "app/assets/stylesheets/components.css", <<~CSS
        .button { background: #0066ff; color: #ffffff; }
      CSS

      result = described_class.new(root).detect
      expect(result.strategy).to eq(:raw_hex)
      expect(result.evidence[:raw_hex_files]).to eq(1)
    end

    it "does not count hex inside SCSS variable definitions as raw" do
      write_stylesheet "app/assets/stylesheets/_tokens.scss", <<~SCSS
        $primary: #0066ff;
        $secondary: #fa3;
      SCSS

      result = described_class.new(root).detect
      expect(result.strategy).to eq(:scss_variables)
      expect(result.evidence[:raw_hex_files]).to eq(0)
    end

    it "picks the dominant strategy when stacks are mixed" do
      write_stylesheet "app/assets/stylesheets/_tokens.scss", "$a: #fa3;\n$b: #abc;"
      write_stylesheet "app/assets/stylesheets/_other.scss", "$c: #def;"
      write_stylesheet "app/assets/stylesheets/raw.css", ".x { color: #f00; }"

      expect(described_class.new(root).detect.strategy).to eq(:scss_variables)
    end

    it "scans the tailwind asset directory" do
      write_stylesheet "app/assets/tailwind/application.css", <<~CSS
        @theme {
          --color-primary: #0066ff;
        }
      CSS

      result = described_class.new(root).detect
      expect(result.strategy).to eq(:css_custom_properties)
      expect(result.evidence[:files_scanned]).to eq(1)
    end
  end
end
