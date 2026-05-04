# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/init/media_query_scaffolder"

RSpec.describe Guardrails::Init::MediaQueryScaffolder do
  let(:dir) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(dir) }

  describe "#scaffold" do
    it "skips when no file is configured" do
      status, msg = described_class.new(nil, output: StringIO.new).scaffold

      expect(status).to eq(:skipped)
      expect(msg).to include("no colors_file configured")
    end

    it "skips when the file does not exist" do
      status, _ = described_class.new(dir.join("missing.scss"), output: StringIO.new).scaffold

      expect(status).to eq(:skipped)
    end

    it "appends both stubs to a file that has neither" do
      file = dir.join("tokens.scss")
      file.write("$primary: #0066ff;\n")

      status, _ = described_class.new(file, output: StringIO.new).scaffold

      expect(status).to eq(:appended)
      content = file.read(encoding: Encoding::UTF_8)
      expect(content).to include("@media (prefers-color-scheme: dark)")
      expect(content).to include("@media (prefers-contrast: more)")
      expect(content).to include("TODO: fill this in")
    end

    it "preserves existing content above the stubs" do
      file = dir.join("tokens.scss")
      file.write("$primary: #0066ff;\n")

      described_class.new(file, output: StringIO.new).scaffold

      content = file.read(encoding: Encoding::UTF_8)
      expect(content).to start_with("$primary: #0066ff;")
    end

    it "leaves files alone if both stubs already exist" do
      file = dir.join("tokens.scss")
      file.write(<<~SCSS)
        @media (prefers-color-scheme: dark) {}
        @media (prefers-contrast: more) {}
      SCSS
      original = file.read(encoding: Encoding::UTF_8)

      status, _ = described_class.new(file, output: StringIO.new).scaffold

      expect(status).to eq(:already_present)
      expect(file.read(encoding: Encoding::UTF_8)).to eq(original)
    end

    it "adds only the missing stub when one is already present" do
      file = dir.join("tokens.scss")
      file.write("@media (prefers-color-scheme: dark) {}\n")

      status, _ = described_class.new(file, output: StringIO.new).scaffold

      expect(status).to eq(:appended)
      content = file.read(encoding: Encoding::UTF_8)
      expect(content.scan("prefers-color-scheme").length).to eq(1)
      expect(content).to include("prefers-contrast: more")
    end

    it "ensures a trailing newline before appending stubs" do
      file = dir.join("tokens.scss")
      file.write("$primary: #0066ff;") # no trailing newline

      described_class.new(file, output: StringIO.new).scaffold

      content = file.read(encoding: Encoding::UTF_8)
      expect(content).to include("$primary: #0066ff;\n")
    end
  end
end
