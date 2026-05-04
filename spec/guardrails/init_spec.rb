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
end
