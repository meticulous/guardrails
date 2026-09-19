# frozen_string_literal: true

module Guardrails
  module Report
    # Where a finding lives. `line` / `column` are nil for whole-file
    # findings (a dead Stimulus controller, a component with no preview).
    Location = Struct.new(:file, :line, :column, keyword_init: true) do
      def to_s
        [file, line, column].compact.join(":")
      end
    end

    # One detector-agnostic finding. Every detector has its own result
    # struct shaped around what it measures (Violation, Cluster,
    # Pattern, …); Finding is the common denominator that front-ends
    # which list, filter, and link findings render from, so they never
    # need to know which detector produced what.
    #
    # `locations` is plural because the suggestion-tier detectors
    # report one finding spanning many places (a class list repeated
    # in 9 files is one finding, not 9). `details` is an ordered list
    # of [label, value] pairs for detector-specific extras — class
    # list, axe help URL, diff image path.
    Finding = Struct.new(:category, :severity, :title, :suggestion, :locations,
                         :snippet, :details, :auto_fix, keyword_init: true) do
      def locations
        self[:locations] || []
      end

      def details
        self[:details] || []
      end

      def location
        locations.first
      end

      def files
        locations.map(&:file).compact.uniq
      end

      def to_h
        {
          category: category, severity: severity, title: title, suggestion: suggestion,
          locations: locations.map(&:to_h), snippet: snippet,
          details: details.to_h, auto_fix: auto_fix || false
        }
      end
    end

    # A named group of findings plus the framing paragraph that
    # explains what the rule catches. `name` matches the category on
    # the corresponding Summary::Entry, so the rollup and the detail
    # views line up. `severity` is the category's headline severity;
    # individual findings may differ (deep a11y maps axe impact per
    # finding).
    Category = Struct.new(:name, :severity, :framing, :findings, :auto_fix, keyword_init: true) do
      def count
        findings.length
      end
    end
  end
end
