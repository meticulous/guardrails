# frozen_string_literal: true

require "pathname"

module Guardrails
  class Init
    class StackDetector
      Result = Struct.new(:strategy, :stylesheets, :evidence, keyword_init: true)

      STYLESHEET_PATTERNS = [
        "app/assets/stylesheets/**/*.{css,scss}",
        "app/assets/tailwind/**/*.css"
      ].freeze

      CUSTOM_PROPERTY_PATTERN = /--[a-z][\w-]*:\s*[^;]+;/
      SCSS_VARIABLE_PATTERN = /^\s*\$[a-z][\w-]*:/
      HEX_LITERAL_PATTERN = /#[0-9a-fA-F]{3,8}\b/

      def initialize(root)
        @root = Pathname(root)
      end

      def detect
        files = collect_stylesheets
        return Result.new(strategy: :none, stylesheets: [], evidence: empty_evidence) if files.empty?

        evidence = analyze(files)
        Result.new(
          strategy: choose_strategy(evidence),
          stylesheets: files,
          evidence: evidence
        )
      end

      private

      def collect_stylesheets
        STYLESHEET_PATTERNS
          .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
          .map { |path| Pathname(path) }
          .uniq
      end

      def empty_evidence
        {
          files_scanned: 0,
          custom_property_files: 0,
          scss_variable_files: 0,
          raw_hex_files: 0
        }
      end

      def analyze(files)
        evidence = empty_evidence
        evidence[:files_scanned] = files.length

        files.each do |file|
          # Force UTF-8 — real-world stylesheets routinely contain
          # multi-byte chars (em-dashes in comments, smart quotes in
          # string values, etc.) and Pathname#read uses the default
          # external encoding which can be US-ASCII on some systems.
          content = File.read(file, encoding: Encoding::UTF_8)
          has_custom_props = content.match?(CUSTOM_PROPERTY_PATTERN)
          has_scss_vars = content.match?(SCSS_VARIABLE_PATTERN)
          has_hex = content.match?(HEX_LITERAL_PATTERN)

          evidence[:custom_property_files] += 1 if has_custom_props
          evidence[:scss_variable_files] += 1 if has_scss_vars
          evidence[:raw_hex_files] += 1 if has_hex && !has_custom_props && !has_scss_vars
        end

        evidence
      end

      def choose_strategy(evidence)
        scores = {
          css_custom_properties: evidence[:custom_property_files],
          scss_variables: evidence[:scss_variable_files],
          raw_hex: evidence[:raw_hex_files]
        }
        return :none if scores.values.all?(&:zero?)

        scores.max_by { |_, count| count }.first
      end
    end
  end
end
