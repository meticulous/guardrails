# frozen_string_literal: true

require_relative "summary"

module Guardrails
  module Report
    # Detectors other gems add to `rake ui_guardrails:audit`, run after the
    # built-ins. ui_guardrails-browser registers its heuristic review
    # here.
    #
    #     Guardrails::Report::Detectors.register(:heuristics, HeuristicsDetector)
    #
    # A registered detector class answers:
    #
    #   .enabled?(env:)       whether this audit runs it; env is the
    #                         audit's environment (ENV or a Hash)
    #   .max_severity         the most serious severity it reports, so
    #                         SEVERITY= can skip it instead of running it
    #                         and discarding everything
    #   .new(root:, output:, style:)
    #   #run                  returns its result and prints its own
    #                         section to output
    #   #categories(result)   Report::Categories; detail labels unique,
    #                         values strings
    #   #summary_entry(result)  a Summary::Entry for the rollup
    #   #to_h(result)         its FORMAT=json fragment, under
    #                         `extensions.<name>`
    #   #failing?(result)     its own exit-code rule
    #
    # Detectors only read what's already on disk. They never capture
    # or call an API: the TUI re-runs every detector on each `r`.
    module Detectors
      CLASS_METHODS = %i[enabled? max_severity].freeze
      INSTANCE_METHODS = %i[run categories summary_entry to_h failing?].freeze

      @registered = {}

      class << self
        def register(name, detector_class)
          missing = CLASS_METHODS.reject { |m| detector_class.respond_to?(m) }.map { |m| ".#{m}" } +
                    INSTANCE_METHODS.reject { |m| detector_class.method_defined?(m) }.map { |m| "##{m}" }
          unless missing.empty?
            raise ArgumentError, "#{detector_class} can't be registered as a detector; it's missing #{missing.join(", ")}"
          end
          unless Summary::SEVERITY_ORDER.include?(detector_class.max_severity)
            raise ArgumentError, "#{detector_class}.max_severity must be one of #{Summary::SEVERITY_ORDER.inspect}"
          end

          @registered[name.to_sym] = detector_class
        end

        def unregister(name)
          @registered.delete(name.to_sym)
        end

        def registered
          @registered.dup
        end

        # The registered detectors this environment switches on.
        def enabled(env)
          @registered.select { |_name, detector_class| detector_class.enabled?(env: env) }
        end
      end
    end
  end
end
