# frozen_string_literal: true

require "pathname"
require_relative "../hex_normalizer"
require_relative "../token_matcher"

module Guardrails
  class Audit
    class AutoFixer
      Result = Struct.new(:violation, :token, :kind, :distance, :replacement, keyword_init: true)

      def initialize(root, output: $stdout, tokens: [], near_match_policy: "notify")
        @root = Pathname(root)
        @output = output
        @matcher = TokenMatcher.new(tokens)
        @near_match_policy = near_match_policy
      end

      def apply(violations)
        applicable = violations.select { |v| applicable?(v) }
        return [] if applicable.empty?

        applied = applicable.group_by(&:file).flat_map do |file, file_violations|
          process_file(@root.join(file), file_violations)
        end

        report(applied)
        applied
      end

      def applicable?(violation)
        return false unless violation.type == :raw_color

        match = applicable_match(violation)
        !match.nil? && match.token.syntax == :css_var
      end

      private

      def applicable_match(violation)
        match = @matcher.match(violation.value)
        return nil unless match
        return match if match.kind == :exact
        return match if match.kind == :near && @near_match_policy == "fix"

        nil
      end

      def process_file(path, violations)
        return [] unless path.exist?

        original = File.read(path, encoding: Encoding::UTF_8)
        lines = original.lines
        applied = []

        violations.group_by(&:line).each do |line_num, line_violations|
          line_idx = line_num - 1
          next unless lines[line_idx]

          line_violations.sort_by { |v| -v.column }.each do |v|
            match = applicable_match(v)
            next unless match

            current_line = lines[line_idx]
            start_idx = v.column - 1
            value_length = v.value.length
            next unless current_line[start_idx, value_length] == v.value

            replacement = "var(--#{match.token.name})"
            lines[line_idx] = current_line[0...start_idx] + replacement + current_line[(start_idx + value_length)..]
            applied << Result.new(
              violation: v,
              token: match.token,
              kind: match.kind,
              distance: match.distance,
              replacement: replacement
            )
          end
        end

        new_content = lines.join
        File.write(path, new_content, encoding: Encoding::UTF_8) if new_content != original
        applied
      end

      def report(applied)
        return if applied.empty?

        @output.puts ""
        noun = applied.length == 1 ? "fix" : "fixes"
        @output.puts "Guardrails audit: applied #{applied.length} auto-#{noun} (raw_color → CSS custom property)"
        applied.each do |r|
          suffix = r.kind == :near ? " [NEAR MATCH, channel diff #{r.distance}]" : ""
          @output.puts "  #{r.violation.file}:#{r.violation.line}  #{r.violation.value} → #{r.replacement}#{suffix}"
        end
      end
    end
  end
end
