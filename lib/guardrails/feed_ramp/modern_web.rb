# frozen_string_literal: true

require "pathname"
require_relative "../../guardrails"

module Guardrails
  module FeedRamp
    # Modern Web Guidance (https://developer.chrome.com/docs/modern-web-guidance):
    # a skill that has coding agents look up current web platform practice
    # (dialogs, popovers, forms, layout, performance, accessibility) before
    # they write HTML, CSS or client-side JavaScript. By Google Chrome and
    # its contributors, stewarded with the Microsoft Edge, Mozilla Firefox
    # and MDN teams; code Apache-2.0, guides CC BY 4.0.
    #
    # Feed Ramp tells agents what this app already has; Modern Web
    # Guidance tells them what the platform already has. Nothing of it is
    # bundled here: the install is theirs (`npx modern-web-guidance
    # install`), run by `rake ui_guardrails:feed_ramp:modern_web:install`,
    # and the agent rules mention the skill once it's in the project.
    module ModernWeb
      NAME = "Modern Web Guidance"
      SKILL = "modern-web-guidance"
      URL = "https://developer.chrome.com/docs/modern-web-guidance"
      SOURCE_URL = "https://github.com/GoogleChrome/modern-web-guidance"
      CREDIT = "#{NAME} is by Google Chrome and its contributors, stewarded with the Microsoft Edge, " \
               "Mozilla Firefox and MDN teams (code Apache-2.0, guides CC BY 4.0): #{URL}".freeze
      TELEMETRY = "Its CLI sends Google anonymous usage data (installs, the calling agent, guide IDs and " \
                  "the agent's search queries). Set DISABLE_TELEMETRY=1 in your shell profile to opt out.".freeze

      # Where agents keep project skills: `.agents/skills`, `.claude/skills`,
      # `.cursor/skills` and so on, some of them links to the first.
      SKILL_GLOB = ".*/skills/#{SKILL}/SKILL.md".freeze

      # Whether the skill is installed in the project (not in the user's
      # home directory or as an agent plugin, which only that user has).
      def self.installed?(root)
        Dir.glob(SKILL_GLOB, base: root.to_s).any?
      end

      # Runs Modern Web Guidance's own installer in the project, after
      # saying whose it is and what it collects.
      class Install
        COMMAND = ["npx", "-y", "#{SKILL}@latest", "install"].freeze

        # `runner` takes the command's words and answers true, false, or
        # nil when it couldn't be started, as `Kernel#system` does.
        def initialize(root:, output: $stdout, runner: nil)
          @root = Pathname(root)
          @output = output
          @runner = runner || ->(*command) { system(*command, chdir: @root.to_s) }
        end

        # `args` go to the installer as given. True when it succeeded.
        def call(args = [])
          @output.puts CREDIT
          @output.puts TELEMETRY
          @output.puts ""

          command = COMMAND + args
          case @runner.call(*command)
          when true then report_installed
          when nil then raise Error, "Couldn't run `#{command.join(" ")}`: #{NAME} needs Node.js 22 or later (npx)."
          else false
          end
        end

        private

        def report_installed
          @output.puts ""
          if ModernWeb.installed?(@root)
            @output.puts "Run `rake ui_guardrails:feed_ramp:rules` to mention the skill in the agent rules, " \
                         "and commit the skill with them."
          else
            @output.puts "The skill isn't in this project, so the agent rules won't mention it. If your team " \
                         "installs it another way, set `feed_ramp.modern_web_guidance: true` in guardrails.yml."
          end
          true
        end
      end
    end
  end
end
