# frozen_string_literal: true

module Guardrails
  # Ruby-level configuration object, intended for `config/initializers/
  # guardrails.rb` in embedded (in-Gemfile) installs:
  #
  #     Guardrails.configure do |c|
  #       c.visual_diff.enabled    = true
  #       c.visual_diff.threshold  = 0.02   # tolerate up to 2% mismatch
  #       c.visual_diff.snap_diff_dir = "spec/screenshots"
  #     end
  #
  # Precedence across config sources (highest → lowest):
  #
  #   1. Environment variables (runtime overrides — same env vars
  #      sidecar-mode users already rely on)
  #   2. `Guardrails.configure` block (embedded-mode initializer)
  #   3. `guardrails.yml` (file-based, both modes — existing surface)
  #   4. Built-in defaults
  #
  # In 0.8.0 the only section is `visual_diff`. Existing detectors
  # continue using their constructor-injected configuration + yml
  # access pattern — migrating them onto this object is a separate
  # refactor (see issue #15 follow-up scope).
  class Configuration
    attr_reader :visual_diff

    def initialize
      @visual_diff = VisualDiffConfig.new
    end

    # Nested configuration for the visual-diff audit. Adapter selection
    # determines which screenshot-tool output we ingest; per-adapter
    # paths and a global threshold round it out.
    class VisualDiffConfig
      # Built-in defaults — kept here, not in env-var fallback logic,
      # so a user reading the Configuration class can see "what does
      # Guardrails ship with" without grepping rake tasks.
      DEFAULT_ADAPTER       = :snap_diff
      DEFAULT_SNAP_DIFF_DIR = "doc/screenshots"
      DEFAULT_THRESHOLD     = 0.0 # any non-zero mismatch fails
      KNOWN_ADAPTERS        = %i[snap_diff backstop].freeze

      attr_accessor :enabled, :adapter, :snap_diff_dir, :backstop_json, :threshold

      def initialize
        @enabled       = false # opt-in: visual baselines need deliberate setup
        @adapter       = DEFAULT_ADAPTER
        @snap_diff_dir = DEFAULT_SNAP_DIFF_DIR
        @backstop_json = nil
        @threshold     = DEFAULT_THRESHOLD
      end

      def adapter=(value)
        sym = value.to_sym
        unless KNOWN_ADAPTERS.include?(sym)
          raise ArgumentError,
                "Unknown visual_diff adapter #{value.inspect}; expected one of #{KNOWN_ADAPTERS.inspect}"
        end
        @adapter = sym
      end

      def threshold=(value)
        float = Float(value)
        unless float >= 0.0 && float <= 1.0
          raise ArgumentError,
                "visual_diff.threshold must be between 0.0 and 1.0; got #{value.inspect}"
        end
        @threshold = float
      end
    end
  end

  class << self
    # Cached Configuration singleton. Tests can reset via
    # `Guardrails.reset_configuration!` so changes in one example
    # don't leak into another.
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
