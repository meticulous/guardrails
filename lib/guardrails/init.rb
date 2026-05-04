# frozen_string_literal: true

require "pathname"
require_relative "init/stack_detector"

module Guardrails
  class Init
    STRATEGY_LABELS = {
      css_custom_properties: "CSS custom properties",
      scss_variables: "SCSS variables",
      raw_hex: "Raw hex literals (no token system detected)",
      none: "No stylesheets found"
    }.freeze

    def initialize(root:, output: $stdout)
      @root = Pathname(root)
      @output = output
    end

    def run
      result = StackDetector.new(@root).detect
      print_summary(result)
      result
    end

    private

    def print_summary(result)
      @output.puts "Guardrails — stack detection"
      @output.puts "Root: #{@root}"
      @output.puts "Strategy: #{STRATEGY_LABELS.fetch(result.strategy)} (#{result.strategy})"
      @output.puts "Stylesheets scanned: #{result.evidence[:files_scanned]}"
      @output.puts "  custom-property files: #{result.evidence[:custom_property_files]}"
      @output.puts "  SCSS-variable files:   #{result.evidence[:scss_variable_files]}"
      @output.puts "  raw-hex files:         #{result.evidence[:raw_hex_files]}"
    end
  end
end
