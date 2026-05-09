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

      # Pick the dominant strategy by file count, but with a strong
      # preference for actual token systems over raw_hex. If any token
      # files exist (CSS custom properties or SCSS variables), choose
      # whichever has more — even if raw_hex has more files than either.
      # raw_hex only wins when no token system is present at all.
      def choose_strategy(evidence)
        css_count = evidence[:custom_property_files]
        scss_count = evidence[:scss_variable_files]
        hex_count = evidence[:raw_hex_files]

        return :none if css_count.zero? && scss_count.zero? && hex_count.zero?

        # If any token system exists, pick the dominant one — never fall
        # back to raw_hex when SCSS / CSS-vars are in play.
        if css_count.positive? || scss_count.positive?
          return css_count >= scss_count ? :css_custom_properties : :scss_variables
        end

        :raw_hex
      end
    end
  end
end
