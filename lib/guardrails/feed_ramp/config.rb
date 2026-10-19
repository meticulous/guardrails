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
    #
    # Lookbook's own `preview_paths` live in Rails config, which Feed Ramp
    # can't read without booting the app; list them here when they aren't
    # one of the defaults.
    class Config
      DEFAULT_COMPONENT_PATHS = %w[app/components app/views/components].freeze
      DEFAULT_PREVIEW_PATHS = %w[test/components/previews spec/components/previews lookbook/previews].freeze
      DEFAULT_OUTPUT_DIR = ".ui_guardrails"

      attr_reader :component_paths, :preview_paths, :token_files, :output_dir

      def self.load(root)
        path = Pathname(root).join("guardrails.yml")
        section = path.file? ? (YAML.safe_load_file(path) || {}).dig("guardrails", "feed_ramp") : nil
        new(**(section || {}).transform_keys(&:to_sym).slice(:component_paths, :preview_paths, :token_files, :output_dir))
      rescue Psych::Exception
        new
      end

      def initialize(component_paths: DEFAULT_COMPONENT_PATHS, preview_paths: DEFAULT_PREVIEW_PATHS,
                     token_files: [], output_dir: DEFAULT_OUTPUT_DIR)
        @component_paths = Array(component_paths).map(&:to_s)
        @preview_paths = Array(preview_paths).map(&:to_s)
        @token_files = Array(token_files).map(&:to_s)
        @output_dir = output_dir.to_s
      end
    end
  end
end
