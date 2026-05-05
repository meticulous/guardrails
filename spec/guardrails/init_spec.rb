# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/init"

RSpec.describe Guardrails::Init do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  it "runs detection and prints a summary" do
    output = StringIO.new
    described_class.new(root: root, output: output).run

    expect(output.string).to include("Guardrails — stack detection")
    expect(output.string).to include("Strategy: No stylesheets found (none)")
  end

  it "returns the detection result" do
    result = described_class.new(root: root, output: StringIO.new).run

    expect(result.strategy).to eq(:none)
  end

  it "writes guardrails.yml as part of the run" do
    described_class.new(root: root, output: StringIO.new).run

    expect(root.join("guardrails.yml")).to exist
  end

  it "skips media-query scaffolding when guardrails.yml already exists" do
    root.join("guardrails.yml").write("# pre-existing")
    root.join("app/assets/stylesheets/tokens").mkpath
    token_file = root.join("app/assets/stylesheets/tokens/_colors.scss")
    token_file.write("$primary: #0066ff;\n")

    output = StringIO.new
    described_class.new(root: root, output: output).run

    expect(output.string).to include("refusing to overwrite")
    expect(output.string).to include("Media queries: skipped")
    expect(token_file.read(encoding: Encoding::UTF_8)).not_to include("prefers-color-scheme")
  end
end
