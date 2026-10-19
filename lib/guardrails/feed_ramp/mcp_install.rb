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
      # entry names the project with `${workspaceFolder}`.
      AGENTS = {
        "claude" => ".mcp.json",
        "cursor" => ".cursor/mcp.json",
        "gemini" => ".gemini/settings.json"
      }.freeze

      Change = Struct.new(:agent, :path, :changed, keyword_init: true)

      def initialize(root:, agents: %w[claude])
        @root = Pathname(root)
        @agents = agents.map(&:to_s)
        unknown = @agents - AGENTS.keys
        raise Error, "Unknown agent #{unknown.join(", ")}; expected #{AGENTS.keys.join(", ")} or all" if unknown.any?
      end

      def call
        @agents.map do |agent|
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
