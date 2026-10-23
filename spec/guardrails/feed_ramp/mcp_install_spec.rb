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

  describe "Codex" do
    it "adds a table to .codex/config.toml, keeping the rest of the file" do
      write_file("Gemfile", %(gem "ui_guardrails"\n))
      original = %(model = "gpt-5"\n\n[mcp_servers.docs]\ncommand = "docs-mcp"\n)
      write_file(".codex/config.toml", original)

      expect(described_class.new(root: @root, agents: %w[codex]).call.map(&:to_h))
        .to eq([{ agent: "codex", path: ".codex/config.toml", changed: true }])
      expect(@root.join(".codex/config.toml").read).to eq(
        "#{original}\n[mcp_servers.ui_guardrails]\ncommand = \"bundle\"\nargs = [\"exec\", \"ui_guardrails-mcp\"]\n"
      )
      expect(described_class.new(root: @root, agents: %w[codex]).call.first.changed).to be false
    end

    it "replaces its own table and anything nested under it, in place" do
      write_file(".codex/config.toml", <<~TOML)
        [mcp_servers.ui_guardrails]
        command = "old"
        startup_timeout_sec = 5

        [mcp_servers.ui_guardrails.env]
        OLD = "1"

        # The docs server
        [mcp_servers.docs]
        command = "docs-mcp"
      TOML
      described_class.new(root: @root, agents: %w[codex]).call

      expect(@root.join(".codex/config.toml").read).to eq(<<~TOML)
        [mcp_servers.ui_guardrails]
        command = "ui_guardrails-mcp"
        args = []

        # The docs server
        [mcp_servers.docs]
        command = "docs-mcp"
      TOML
    end

    it "creates the file, and refuses one that sets the server up some other way" do
      described_class.new(root: @root, agents: %w[codex]).call
      expect(@root.join(".codex/config.toml").read).to eq(%([mcp_servers.ui_guardrails]\ncommand = "ui_guardrails-mcp"\nargs = []\n))

      write_file(".codex/config.toml", %([mcp_servers]\nui_guardrails = { command = "x" }\n))
      expect { described_class.new(root: @root, agents: %w[codex]).call }
        .to raise_error(Guardrails::Error, /\.codex\/config\.toml sets up ui_guardrails in a form this task can't edit/)
    end
  end

  it "refuses invalid JSON and unknown agents" do
    write_file(".mcp.json", "{ nope")
    expect { described_class.new(root: @root).call }.to raise_error(Guardrails::Error, /\.mcp\.json isn't valid JSON/)
    expect(@root.join(".mcp.json").read).to eq("{ nope")
    expect { described_class.new(root: @root, agents: %w[windsurf]) }.to raise_error(Guardrails::Error, /Unknown agent windsurf/)
  end
end
