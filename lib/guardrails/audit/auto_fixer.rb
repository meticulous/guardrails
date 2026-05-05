# frozen_string_literal: true

require "pathname"
require_relative "../hex_normalizer"
require_relative "../token_matcher"

module Guardrails
  class Audit
    class AutoFixer
      Result = Struct.new(:violation, :token, :kind, :distance, :replacement, keyword_init: true)

      # Each violation type maps to the token syntaxes that can substitute
      # for it in source. raw_color in a view attribute can only become
      # var(--name); tailwind_arbitrary in a class string can only become
      # a named utility derived from a Tailwind theme color.
      COMPATIBLE_SYNTAX = {
        raw_color: [:css_var],
        tailwind_arbitrary: [:tailwind]
      }.freeze

      def initialize(root, output: $stdout, tokens: [], near_match_policy: "notify",
                     near_match_threshold: TokenMatcher::NEAR_MATCH_THRESHOLD)
        @root = Pathname(root)
        @output = output
        @near_match_policy = near_match_policy
        @matchers = build_matchers(tokens, near_match_threshold)
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
        !applicable_match(violation).nil?
      end

      private

      def build_matchers(tokens, threshold)
        COMPATIBLE_SYNTAX.transform_values do |syntaxes|
          subset = tokens.select { |t| syntaxes.include?(t.syntax) }
          TokenMatcher.new(subset, near_match_threshold: threshold)
        end
      end

      def applicable_match(violation)
        matcher = @matchers[violation.type]
        return nil unless matcher

        match = matcher.match(violation.value)
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

            edit = build_edit(v, match, lines[line_idx])
            next unless edit

            start_idx, length, replacement = edit
            lines[line_idx] = lines[line_idx][0...start_idx] + replacement + lines[line_idx][(start_idx + length)..]
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

      # Returns [start_idx, length, replacement_string] for the in-line edit,
      # or nil if the source no longer matches the violation's expected text.
      def build_edit(violation, match, line)
        case violation.type
        when :raw_color
          start_idx = violation.column - 1
          length = violation.value.length
          return nil unless line[start_idx, length] == violation.value

          [start_idx, length, "var(--#{match.token.name})"]
        when :tailwind_arbitrary
          tailwind_edit(violation, match, line)
        end
      end

      # For `bg-[#0066ff]`, walk back from the `[` to the start of the prefix
      # (stopping at whitespace, quote, or `:` to preserve variants like
      # `lg:hover:bg-[...]`), then replace the whole `prefix-[value]` span
      # with `prefix-tokenname`.
      def tailwind_edit(violation, match, line)
        bracket_start = violation.column - 1
        return nil unless line[bracket_start] == "["

        bracket_end = line.index("]", bracket_start)
        return nil unless bracket_end
        return nil unless bracket_start.positive? && line[bracket_start - 1] == "-"

        prefix_dash = bracket_start - 1
        prefix_start = prefix_dash
        prefix_start -= 1 while prefix_start.positive? && line[prefix_start - 1] !~ /[\s"':]/

        prefix = line[prefix_start...prefix_dash]
        return nil if prefix.empty?

        full_length = bracket_end - prefix_start + 1
        [prefix_start, full_length, "#{prefix}-#{match.token.name}"]
      end

      def report(applied)
        return if applied.empty?

        applied.group_by { |r| r.violation.type }.each do |type, results|
          label = type == :raw_color ? "raw_color → CSS custom property" : "tailwind_arbitrary → named utility"
          noun = results.length == 1 ? "fix" : "fixes"
          @output.puts ""
          @output.puts "Guardrails audit: applied #{results.length} auto-#{noun} (#{label})"
          results.each do |r|
            suffix = r.kind == :near ? " [NEAR MATCH, channel diff #{r.distance}]" : ""
            @output.puts "  #{r.violation.file}:#{r.violation.line}  #{r.violation.value} → #{r.replacement}#{suffix}"
          end
        end
      end
    end
  end
end
