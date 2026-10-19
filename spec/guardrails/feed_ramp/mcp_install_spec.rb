# frozen_string_literal: true

require "tmpdir"
require "json"
require "guardrails/feed_ramp/mcp_install"

RSpec.describe Guardrails::FeedRamp::MCPInstall do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  def write_file(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def json(path)
    JSON.parse(@root.join(path).read)
  end

  it "adds the server to .mcp.json, using bundle exec when the Gemfile has the gem" do
    write_file("Gemfile", %(source "https://rubygems.org"\ngem "ui_guardrails"\n))
    changes = described_class.new(root: @root).call

    expect(changes.map(&:to_h)).to eq([{ agent: "claude", path: ".mcp.json", changed: true }])
    expect(json(".mcp.json")).to eq(
      "mcpServers" => { "ui_guardrails" => { "type" => "stdio", "command" => "bundle", "args" => %w[exec ui_guardrails-mcp] } }
    )
  end

  it "uses the bare executable for a sidecar install" do
    described_class.new(root: @root).call
    expect(json(".mcp.json").dig("mcpServers", "ui_guardrails")).to eq("type" => "stdio", "command" => "ui_guardrails-mcp", "args" => [])
  end

  it "points Cursor at the workspace, and keeps Gemini's other settings" do
    write_file("Gemfile", %(gem "ui_guardrails", group: :development\n))
    write_file(".gemini/settings.json", JSON.generate("hooks" => { "AfterAgent" => [] }, "mcpServers" => { "other" => { "command" => "x" } }))
    described_class.new(root: @root, agents: %w[cursor gemini]).call

    expect(json(".cursor/mcp.json").dig("mcpServers", "ui_guardrails")).to eq(
      "type" => "stdio", "command" => "bundle", "args" => ["exec", "ui_guardrails-mcp", "--root", "${workspaceFolder}"],
      "env" => { "BUNDLE_GEMFILE" => "${workspaceFolder}/Gemfile" }
    )
    expect(json(".gemini/settings.json")).to eq(
      "hooks" => { "AfterAgent" => [] },
      "mcpServers" => { "other" => { "command" => "x" }, "ui_guardrails" => { "command" => "bundle", "args" => %w[exec ui_guardrails-mcp] } }
    )
  end

  it "changes nothing the second time, and replaces an older entry of its own" do
    write_file(".mcp.json", JSON.generate("mcpServers" => { "ui_guardrails" => { "command" => "old" }, "keep" => { "command" => "y" } }))
    expect(described_class.new(root: @root).call.first.changed).to be true
    before = @root.join(".mcp.json").read
    expect(described_class.new(root: @root).call.first.changed).to be false
    expect(@root.join(".mcp.json").read).to eq(before)
    expect(json(".mcp.json")["mcpServers"]).to include("keep" => { "command" => "y" })
  end

  it "refuses invalid JSON and unknown agents" do
    write_file(".mcp.json", "{ nope")
    expect { described_class.new(root: @root).call }.to raise_error(Guardrails::Error, /\.mcp\.json isn't valid JSON/)
    expect(@root.join(".mcp.json").read).to eq("{ nope")
    expect { described_class.new(root: @root, agents: %w[windsurf]) }.to raise_error(Guardrails::Error, /Unknown agent windsurf/)
  end
end
