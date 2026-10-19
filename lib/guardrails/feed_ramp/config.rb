# frozen_string_literal: true

require "pathname"
require "yaml"

module Guardrails
  module FeedRamp
    # The `feed_ramp:` section of guardrails.yml. Every key is optional:
    #
    #     guardrails:
    #       feed_ramp:
    #         component_paths: [app/components, app/views/components]
    #         preview_paths: [test/components/previews, spec/components/previews]
    #         token_files: [app/assets/stylesheets/tokens/_spacing.css]
    #         output_dir: .ui_guardrails
    #         rules_targets: [claude, agents, cursor]
    #         component_match:
    #           severity: warning   # or suggestion (reports, never fails), error, off
    #           min_classes: 3      # a component's root needs this many static classes to be matched
    #           coverage: 0.8       # share of those classes hand-written markup must carry
    #
    # Lookbook's own `preview_paths` live in Rails config, which Feed Ramp
    # can't read without booting the app; list them here when they aren't
    # one of the defaults.
    class Config
      DEFAULT_COMPONENT_PATHS = %w[app/components app/views/components].freeze
      DEFAULT_PREVIEW_PATHS = %w[test/components/previews spec/components/previews lookbook/previews].freeze
      DEFAULT_OUTPUT_DIR = ".ui_guardrails"
      DEFAULT_RULES_TARGETS = %w[claude agents cursor].freeze
      MANIFEST_FILENAME = "manifest.json"
      MARKDOWN_FILENAME = "COMPONENTS.md"

      # How `component_match` in the audit flags hand-written markup that
      # copies a component's root element. `severity` is nil when off.
      ComponentMatch = Struct.new(:severity, :min_classes, :coverage, keyword_init: true)
      SEVERITIES = { "error" => :error, "warning" => :warning, "suggestion" => :suggestion, "off" => nil }.freeze
      DEFAULT_COMPONENT_MATCH = { "severity" => "warning", "min_classes" => 3, "coverage" => 0.8 }.freeze

      attr_reader :component_paths, :preview_paths, :token_files, :output_dir, :rules_targets, :component_match

      def self.load(root)
        path = Pathname(root).join("guardrails.yml")
        section = path.file? ? (YAML.safe_load_file(path) || {}).dig("guardrails", "feed_ramp") : nil
        keys = %i[component_paths preview_paths token_files output_dir rules_targets component_match]
        new(**(section || {}).transform_keys(&:to_sym).slice(*keys))
      rescue Psych::Exception
        new
      end

      def initialize(component_paths: DEFAULT_COMPONENT_PATHS, preview_paths: DEFAULT_PREVIEW_PATHS,
                     token_files: [], output_dir: DEFAULT_OUTPUT_DIR, rules_targets: DEFAULT_RULES_TARGETS,
                     component_match: {})
        @component_paths = Array(component_paths).map(&:to_s)
        @preview_paths = Array(preview_paths).map(&:to_s)
        @token_files = Array(token_files).map(&:to_s)
        @output_dir = output_dir.to_s
        @rules_targets = Array(rules_targets).map(&:to_s)
        @component_match = parse_component_match(component_match)
      end

      def manifest_path(root)
        Pathname(root).join(@output_dir, MANIFEST_FILENAME)
      end

      def markdown_path(root)
        Pathname(root).join(@output_dir, MARKDOWN_FILENAME)
      end

      private

      # `component_match: suggestion` is short for setting the severity.
      # A typo raises rather than quietly changing what fails the audit.
      def parse_component_match(value)
        value = { "severity" => value } unless value.is_a?(Hash)
        settings = DEFAULT_COMPONENT_MATCH.merge(value.transform_keys(&:to_s).compact)
        severity = settings["severity"] == false ? "off" : settings["severity"].to_s.strip.downcase # YAML reads `off` as false
        unless SEVERITIES.key?(severity)
          raise ArgumentError, "feed_ramp.component_match severity #{settings["severity"].inspect} in guardrails.yml " \
                               "isn't one of #{SEVERITIES.keys.join(", ")}"
        end

        ComponentMatch.new(severity: SEVERITIES[severity], **numbers(settings))
      end

      def numbers(settings)
        { min_classes: Integer(settings["min_classes"]), coverage: Float(settings["coverage"]) }
      rescue TypeError, ArgumentError
        raise ArgumentError, "feed_ramp.component_match in guardrails.yml needs a whole-number min_classes " \
                             "and a coverage between 0 and 1"
      end
    end
  end
end
