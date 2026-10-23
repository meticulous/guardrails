# frozen_string_literal: true

require "tmpdir"
require "open3"
require "guardrails/hooks/runner"
require "guardrails/hooks/installer"

RSpec.describe Guardrails::Hooks::Runner do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir).realpath
      example.run
    end
  end

  let(:env) { { "BUNDLE_GEMFILE" => @root.join("Gemfile").to_s } }
  let(:template) { "app/views/pages/a.html.erb" }

  def write(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def git(*args)
    _out, err, status = Open3.capture3("git", *GitHelper::QUIET_CONFIG, *args, chdir: @root.to_s)
    raise err unless status.success?
  end

  before do
    write("Gemfile", %(gem "ui_guardrails"\n))
    write(template, "<p>ok</p>\n")
    git("init", "-q")
    git("add", ".")
    git("commit", "-qm", "init")
    write(template, %(<p>ok</p>\n<img src="x.png">\n))
  end

  def run(agent, event, input, hook_env = env)
    result = described_class.call(agent: agent, event: event, stdin: JSON.generate(input), env: hook_env)
    expect(result.exit_code).to eq(0)
    [JSON.parse(result.stdout), result.stderr]
  end

  describe "Claude Code" do
    it "returns the drift an edit introduced as additionalContext" do
      out, = run("claude", "edit", "hook_event_name" => "PostToolUse", "tool_name" => "Edit",
                                   "tool_input" => { "file_path" => @root.join(template).to_s })

      expect(out.dig("hookSpecificOutput", "hookEventName")).to eq("PostToolUse")
      expect(out.dig("hookSpecificOutput", "additionalContext")).to include("[error] #{template}:2 image_alt")
    end

    it "blocks a stop with a reason, and lets it through once a stop hook has continued the turn" do
      out, = run("claude", "stop", "hook_event_name" => "Stop", "stop_hook_active" => false)
      expect(out).to include("decision" => "block")
      expect(out["reason"]).to include("before finishing", "image_alt")

      expect(run("claude", "stop", "stop_hook_active" => true).first).to eq({})
    end

    it "says nothing about an edit that introduced nothing" do
      write(template, "<p>ok</p>\n")

      expect(run("claude", "edit", "tool_input" => { "file_path" => @root.join(template).to_s }).first).to eq({})
    end
  end

  describe "Codex" do
    it "reads the edited files from apply_patch's patch, relative to cwd" do
      patch = "*** Begin Patch\n*** Update File: #{template}\n@@\n+<img src=\"x.png\">\n*** End Patch"
      out, = run("codex", "edit", "hook_event_name" => "PostToolUse", "tool_name" => "apply_patch", "cwd" => @root.to_s,
                                  "tool_input" => { "command" => patch })

      expect(out.dig("hookSpecificOutput", "additionalContext")).to include("image_alt")
    end

    it "answers a stop with an object, never empty output" do
      write(template, "<p>ok</p>\n")

      result = described_class.call(agent: "codex", event: "stop", stdin: JSON.generate("stop_hook_active" => false), env: env)
      expect(result.stdout).to eq("{}\n")
    end
  end

  describe "Cursor" do
    it "continues a completed turn with a follow-up message, once" do
      out, = run("cursor", "stop", "hook_event_name" => "stop", "status" => "completed", "loop_count" => 0,
                                   "cursor_version" => "3.13.25", "workspace_roots" => [@root.to_s])
      expect(out["followup_message"]).to include("image_alt")

      expect(run("cursor", "stop", "status" => "completed", "loop_count" => 1).first).to eq({})
      expect(run("cursor", "stop", "status" => "aborted", "loop_count" => 0).first).to eq({})
    end

    it "answers Claude hooks that Cursor runs as Cursor, or not at all when Cursor has its own" do
      input = { "hook_event_name" => "Stop", "status" => "completed", "loop_count" => 0, "cursor_version" => "3.13.25",
                "conversation_id" => "c1", "workspace_roots" => [@root.to_s] }

      expect(run("claude", "stop", input).first).to have_key("followup_message")

      write(".cursor/hooks.json", JSON.generate("version" => 1, "hooks" => { "stop" => [{ "command" => "bundle exec guardrails-hook cursor stop" }] }))
      expect(run("claude", "stop", input).first).to eq({})
    end

    it "strips the byte-order mark Cursor sends on Windows" do
      stdin = "﻿#{JSON.generate("status" => "completed", "loop_count" => 0)}"
      result = described_class.call(agent: "cursor", event: "stop", stdin: stdin, env: env)

      expect(JSON.parse(result.stdout)).to have_key("followup_message")
    end
  end

  describe "Gemini CLI" do
    it "appends drift to the tool result and blocks AfterAgent" do
      out, = run("gemini", "edit", "hook_event_name" => "AfterTool", "tool_name" => "replace", "cwd" => @root.to_s,
                                   "tool_input" => { "file_path" => template })
      expect(out).to eq("hookSpecificOutput" => { "additionalContext" => out.dig("hookSpecificOutput", "additionalContext") })
      expect(out.dig("hookSpecificOutput", "additionalContext")).to include("image_alt")

      expect(run("gemini", "stop", "stop_hook_active" => false).first).to include("decision" => "block")
    end
  end

  it "finds the app from the agent's project directory without bundle exec" do
    out, = run("claude", "stop", { "stop_hook_active" => false }, { "CLAUDE_PROJECT_DIR" => @root.to_s })

    expect(out).to include("decision" => "block")
  end

  it "fails open: an unknown agent or event, or unreadable input, prints {} and explains on stderr" do
    out, err = run("aider", "stop", {})
    expect([out, err]).to match([{}, /Unknown agent "aider"/])

    out, err = run("claude", "precompact", {})
    expect([out, err]).to match([{}, /Unknown event "precompact"/])

    result = described_class.call(agent: "claude", event: "stop", stdin: "{ nope", env: env)
    expect([result.stdout, result.exit_code]).to eq(["{}\n", 0])
    expect(result.stderr).to include("JSON::ParserError")
  end

  it "passes contributors' session-start notes to the agent" do
    contributor = Object.new
    def contributor.on_session_start(_event) = Guardrails::Hooks::Outcome.new(notes: ["1 visual change was rejected."], block: false)
    Guardrails::Hooks.register(:review, contributor)

    out, = run("claude", "session_start", "source" => "startup")
    expect(out.dig("hookSpecificOutput", "additionalContext")).to eq("1 visual change was rejected.")
    expect(run("cursor", "session_start", {}).first).to eq("additional_context" => "1 visual change was rejected.")
  ensure
    Guardrails::Hooks.unregister(:review)
  end

  describe Guardrails::Hooks::Installer do
    it "writes each agent's config, calling the hook through bundle exec, and is idempotent" do
      installer = described_class.new(root: @root, agents: %w[claude codex cursor gemini])
      expect(installer.call.map { |c| [c.agent, c.path, c.changed] }).to eq(
        [["claude", ".claude/settings.json", true], ["codex", ".codex/hooks.json", true],
         ["cursor", ".cursor/hooks.json", true], ["gemini", ".gemini/settings.json", true]]
      )
      expect(installer.call.map(&:changed)).to all(be false)

      claude = JSON.parse(@root.join(".claude/settings.json").read)["hooks"]
      expect(claude["PostToolUse"].first).to include("matcher" => "Edit|Write|MultiEdit")
      expect(claude["Stop"].first["hooks"].first["command"])
        .to eq(%((cd "$CLAUDE_PROJECT_DIR" && bundle exec guardrails-hook claude stop) || echo '{}'))

      codex = JSON.parse(@root.join(".codex/hooks.json").read)["hooks"]
      expect(codex["PostToolUse"].first).to include("matcher" => "^apply_patch$")
      expect(codex["Stop"].first["hooks"].first["command"]).to eq("(bundle exec guardrails-hook codex stop) || echo '{}'")

      cursor = JSON.parse(@root.join(".cursor/hooks.json").read)
      expect(cursor).to include("version" => 1)
      expect(cursor["hooks"].keys).to eq(%w[stop sessionStart])

      gemini = JSON.parse(@root.join(".gemini/settings.json").read)["hooks"]
      expect(gemini["AfterTool"].first).to include("matcher" => "write_file|replace")
      expect(gemini["AfterAgent"].first["hooks"].first).to include("name" => "guardrails", "timeout" => 60_000)
    end

    it "installs commands that answer {} when the hook can't start at all" do
      described_class.new(root: @root, agents: ["claude"]).call
      command = JSON.parse(@root.join(".claude/settings.json").read).dig("hooks", "Stop", 0, "hooks", 0, "command")

      Dir.mktmpdir do |elsewhere|
        # A branch without the gem: no Gemfile where the hook runs.
        out, _err, status = Bundler.with_unbundled_env do
          Open3.capture3({ "CLAUDE_PROJECT_DIR" => elsewhere }, "sh", "-c", command)
        end
        expect([out, status.exitstatus]).to eq(["{}\n", 0])
      end

      out, _err, status = Bundler.with_unbundled_env do
        Open3.capture3({ "CLAUDE_PROJECT_DIR" => @root.join("missing").to_s }, "sh", "-c", command)
      end
      expect([out, status.exitstatus]).to eq(["{}\n", 0])
    end

    it "calls the bare executable when the gem isn't in the Gemfile (sidecar)" do
      write("Gemfile", %(gem "rails"\n))
      described_class.new(root: @root, agents: ["codex"]).call

      codex = JSON.parse(@root.join(".codex/hooks.json").read)["hooks"]
      expect(codex["Stop"].first["hooks"].first["command"]).to eq("(guardrails-hook codex stop) || echo '{}'")
    end
  end
end
