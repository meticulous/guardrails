# frozen_string_literal: true

require "pathname"
require_relative "../hooks"
require_relative "adapters"
require_relative "config_file"

module Guardrails
  module Hooks
    # Writes each agent's hook config for `rake ui_guardrails:hooks:install`,
    # merged into what's there.
    class Installer
      Change = Struct.new(:agent, :path, :changed, keyword_init: true)

      def initialize(root:, agents:)
        @root = Pathname(root)
        @adapters = agents.map { |agent| Adapters.fetch(agent) }
      end

      def call
        @adapters.map do |adapter|
          path = @root.join(adapter.config_path)
          # Falls back to `{}`, the answer every agent reads as "nothing to
          # say", when the hook can't start at all: a branch without the
          # gem in its Gemfile, or a missing project directory.
          command = ->(event) { "(#{adapter.command_prefix}#{executable} #{adapter.name} #{event}) || echo '{}'" }
          changed = ConfigFile.new(path).add(adapter.config_entries(command), extra: adapter.config_extra)
          Change.new(agent: adapter.name, path: path.relative_path_from(@root).to_s, changed: changed)
        end
      end

      private

      # `bundle exec` when the app's Gemfile has the gem; the bare
      # executable for sidecar installs.
      def executable
        gemfile = @root.join("Gemfile")
        bundled = gemfile.file? && gemfile.read.match?(/^\s*gem\s+["']ui_guardrails["']/)
        bundled ? "bundle exec guardrails-hook" : "guardrails-hook"
      end
    end
  end
end
