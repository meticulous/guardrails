# frozen_string_literal: true

require "json"
require "pathname"
require_relative "../../guardrails"

module Guardrails
  module FeedRamp
    # Adds the `ui_guardrails` MCP server to each agent's project config,
    # keeping every other server and setting in the file. Running it
    # again changes nothing.
    class MCPInstall
      SERVER_NAME = "ui_guardrails"
      EXECUTABLE = "ui_guardrails-mcp"

      # Cursor doesn't document the directory it starts servers in, so its
      # entry names the project with `${workspaceFolder}`. Codex reads
      # project config only in projects you've trusted, and starts the
      # server where Codex runs, as the Codex hooks assume.
      AGENTS = {
        "claude" => ".mcp.json",
        "codex" => ".codex/config.toml",
        "cursor" => ".cursor/mcp.json",
        "gemini" => ".gemini/settings.json"
      }.freeze

      # Codex's table for the server, and anything nested under it.
      CODEX_TABLE = /\A\s*\[\s*mcp_servers\s*\.\s*(?:ui_guardrails|"ui_guardrails")\s*(?:\.[^\]]*)?\]\s*(?:#.*)?\z/

      Change = Struct.new(:agent, :path, :changed, keyword_init: true)

      def initialize(root:, agents: %w[claude])
        @root = Pathname(root)
        @agents = agents.map(&:to_s)
        unknown = @agents - AGENTS.keys
        raise Error, "Unknown agent #{unknown.join(", ")}; expected #{AGENTS.keys.join(", ")} or all" if unknown.any?
      end

      def call
        @agents.map do |agent|
          next install_codex if agent == "codex"

          path = @root.join(AGENTS.fetch(agent))
          config = read(path)
          servers = (config["mcpServers"] ||= {})
          raise Error, "#{relative(path)}: `mcpServers` isn't an object" unless servers.is_a?(Hash)

          entry = entry_for(agent)
          changed = servers[SERVER_NAME] != entry
          if changed
            servers[SERVER_NAME] = entry
            path.dirname.mkpath
            path.write("#{JSON.pretty_generate(config)}\n")
          end
          Change.new(agent: agent, path: relative(path), changed: changed)
        end
      end

      private

      # Without a TOML parser, the file is edited as lines: the
      # `[mcp_servers.ui_guardrails]` table (and any table nested under it)
      # is replaced, or added at the end, and nothing else changes.
      def install_codex
        path = @root.join(AGENTS["codex"])
        text = path.file? ? path.read : ""
        lines = text.lines
        owned = owned_lines(lines)
        if owned.empty? && text.match?(/^\s*(?:mcp_servers\s*\.\s*)?"?ui_guardrails"?\s*=/)
          raise Error, "#{relative(path)} sets up ui_guardrails in a form this task can't edit; update it by hand"
        end

        table = codex_table
        updated = if owned.empty?
                    body = text.sub(/\s*\z/, "")
                    body.empty? ? table : "#{body}\n\n#{table}"
                  else
                    kept = lines.reject.with_index { |_, i| owned.include?(i) }
                    kept.insert(owned.first, table).join.sub(/\n*\z/, "\n")
                  end
        changed = updated != text
        if changed
          path.dirname.mkpath
          path.write(updated)
        end
        Change.new(agent: "codex", path: relative(path), changed: changed)
      end

      # Indexes of the lines in the server's tables, less the blank lines
      # and comments at the end of each, which go with what follows.
      def owned_lines(lines)
        owned = lines.each_index.select { |i| owned_line?(lines, i) }
        owned.chunk_while { |a, b| b == a + 1 }.flat_map do |run|
          run.pop while run.length > 1 && lines[run.last].chomp.match?(/\A\s*(?:#.*)?\z/)
          run
        end
      end

      # Whether line i belongs to the server's table: its header, or a
      # line after it before the next table that isn't nested under it.
      def owned_line?(lines, index)
        index.downto(0) do |i|
          line = lines[i].chomp
          next unless line.match?(/\A\s*\[/)

          return line.match?(CODEX_TABLE)
        end
        false
      end

      def codex_table
        command, args = bundled? ? ["bundle", ["exec", EXECUTABLE]] : [EXECUTABLE, []]
        "[mcp_servers.#{SERVER_NAME}]\ncommand = #{JSON.generate(command)}\nargs = #{JSON.generate(args).gsub(",", ", ")}\n"
      end

      def entry_for(agent)
        args = agent == "cursor" ? ["--root", "${workspaceFolder}"] : []
        entry = if bundled?
                  { "command" => "bundle", "args" => ["exec", EXECUTABLE, *args] }
                else
                  { "command" => EXECUTABLE, "args" => args }
                end
        entry["env"] = { "BUNDLE_GEMFILE" => "${workspaceFolder}/Gemfile" } if agent == "cursor" && bundled?
        agent == "gemini" ? entry : { "type" => "stdio" }.merge(entry)
      end

      # `bundle exec` when the app's Gemfile has the gem (same rule as
      # the hooks installer); the bare executable for sidecar installs.
      def bundled?
        gemfile = @root.join("Gemfile")
        gemfile.file? && gemfile.read.match?(/^\s*gem\s+["']ui_guardrails["']/)
      end

      def read(path)
        return {} unless path.file? && !path.read.strip.empty?

        config = JSON.parse(path.read)
        raise Error, "#{relative(path)} isn't a JSON object" unless config.is_a?(Hash)

        config
      rescue JSON::ParserError => e
        raise Error, "#{relative(path)} isn't valid JSON (#{e.message.lines.first.strip}); fix it or add the server by hand"
      end

      def relative(path)
        path.relative_path_from(@root).to_s
      end
    end
  end
end
