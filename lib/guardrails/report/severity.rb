# frozen_string_literal: true

require_relative "summary"

module Guardrails
  module Report
    # The severity floor behind SEVERITY=: "only tell me about findings
    # at least this serious". `:suggestion` (the default) is everything;
    # `:warning` mutes suggestions; `:error` mutes warnings too.
    module Severity
      ORDER = Summary::SEVERITY_ORDER
      DEFAULT = :suggestion

      NAMES = {
        "error" => :error, "errors" => :error,
        "warning" => :warning, "warnings" => :warning,
        "suggestion" => :suggestion, "suggestions" => :suggestion, "suggest" => :suggestion, "all" => :suggestion
      }.freeze

      module_function

      # nil / blank is "not set", not an error — same blank-env
      # tolerance as the VISUAL_DIFF_* vars.
      def parse(value)
        text = value.to_s.strip.downcase
        return DEFAULT if text.empty?

        NAMES.fetch(text) do
          raise ArgumentError, "SEVERITY=#{value} isn't a severity. Use error, warning, or suggestion."
        end
      end

      def include?(severity, floor)
        ORDER.index(severity) <= ORDER.index(floor)
      end

      # The severities a floor hides, most serious first.
      def muted(floor)
        ORDER.reject { |severity| include?(severity, floor) }
      end
    end
  end
end
