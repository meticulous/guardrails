# frozen_string_literal: true

require "pathname"
require "yaml"
require_relative "init/stack_detector"
require_relative "init/config_writer"
require_relative "init/media_query_scaffolder"
require_relative "init/prompter"

module Guardrails
  class Init
    NEAR_MATCH_POLICY_CHOICES = %w[notify fix leave].freeze
    DEFAULT_SCAN_PATHS = %w[app/views app/components].freeze
    DEFAULT_IGNORE = %w[app/views/layouts].freeze

    STRATEGY_LABELS = {
      css_custom_properties: "CSS custom properties",
      scss_variables: "SCSS variables",
      raw_hex: "Raw hex literals (no token system detected)",
      none: "No stylesheets found"
    }.freeze

    def initialize(root:, output: $stdout, input: $stdin, force: false)
      @root = Pathname(root)
      @output = output
      @input = input
      @force = force
    end

    def run
      result = StackDetector.new(@root).detect
      print_summary(result)
      overrides = collect_overrides
      written = ConfigWriter.new(@root, output: @output).write(result, overrides: overrides, force: @force)
      if written
        scaffold_media_queries
      else
        @output.puts "Media queries: skipped (delete guardrails.yml or set FORCE=1 to re-run init)"
      end
      result
    end

    private

    def collect_overrides
      prompter = Prompter.new(input: @input, output: @output)
      {
        near_match_policy: prompter.choose(
          "Near-match auto-fix policy:",
          choices: NEAR_MATCH_POLICY_CHOICES,
          default: "notify"
        ),
        scan_paths: csv(prompter.ask(
          "Audit scan paths (comma-separated):",
          default: DEFAULT_SCAN_PATHS.join(",")
        )),
        ignore: csv(prompter.ask(
          "Audit ignore globs (comma-separated):",
          default: DEFAULT_IGNORE.join(",")
        ))
      }
    end

    def csv(value)
      value.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def scaffold_media_queries
      file = configured_colors_file
      status, message = MediaQueryScaffolder.new(file, output: @output).scaffold
      @output.puts "Media queries: #{message}"
      status
    end

    def configured_colors_file
      config_path = @root.join("guardrails.yml")
      return nil unless config_path.exist?

      config = YAML.safe_load_file(config_path) || {}
      relative = config.dig("guardrails", "tokens", "colors_file")
      relative ? @root.join(relative) : nil
    end

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
