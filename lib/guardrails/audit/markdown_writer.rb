# frozen_string_literal: true

require "pathname"
require_relative "../hex_normalizer"
require_relative "../token_matcher"

module Guardrails
  class Audit
    class MarkdownWriter
      OUTPUT_DIR = "doc"

      SUGGESTIONS = {
        inline_style: {
          rule: "Move styles to a stylesheet using design tokens.",
          replacement: "Extract the styles to a CSS class or component stylesheet that references defined tokens."
        },
        raw_color: {
          rule: "Replace raw color literals with a defined token.",
          replacement: "Use a CSS custom property or SCSS variable from your tokens file (see guardrails.yml → tokens.colors_file)."
        },
        tailwind_arbitrary: {
          rule: "Avoid arbitrary Tailwind values — extend the theme or use an existing utility.",
          replacement: "Add this value to your Tailwind theme (e.g. theme.colors.* or theme.fontSize.*) and reference the named utility instead."
        },
        helper_recommended: {
          rule: "Wrapping ERB output in a literal element hides intent from static analysis and a11y tooling.",
          replacement: "Use the Rails helper for this element so attributes (including aria-*) flow through one place."
        }
      }.freeze

      HELPER_REPLACEMENTS = {
        "button" => "Replace with `tag.button(label, ...)` (or `button_to(label, path)` for form-submission buttons).",
        "a" => "Replace with `link_to(label, path, ...)` so the link text is explicit and helper-managed."
      }.freeze

      # Per-violation-type token compatibility for *suggestions*. Order
      # matters — later syntaxes win on lookup-key collision, so the
      # preferred substitute appears first in code-style and last in this
      # array. tailwind_arbitrary suggests :tailwind utility names by
      # preference but falls back to :css_var (parameterized arbitrary
      # `bg-[var(--name)]`) when no Tailwind theme entry matches.
      COMPATIBLE_SYNTAX = {
        raw_color: [:css_var],
        tailwind_arbitrary: [:css_var, :tailwind]
      }.freeze

      def initialize(root, output: $stdout, now: Time.now, tokens: [], near_match_policy: "notify",
                     near_match_threshold: TokenMatcher::NEAR_MATCH_THRESHOLD)
        @root = Pathname(root)
        @output = output
        @now = now
        @matchers = build_matchers(tokens, near_match_threshold)
        @near_match_policy = near_match_policy
      end

      def write(violations)
        path = output_path
        path.dirname.mkpath
        File.write(path, markdown_for(violations), encoding: Encoding::UTF_8)
        @output.puts "Wrote suggestions to #{path.relative_path_from(@root)}"
        path
      end

      private

      def output_path
        @root.join(OUTPUT_DIR, "guardrails-suggestions-#{timestamp}.md")
      end

      def timestamp
        @now.utc.strftime("%Y%m%dT%H%M%SZ")
      end

      def markdown_for(violations)
        sections = [header(violations)]
        if violations.empty?
          sections << "No violations to suggest fixes for. Nice work."
        else
          group_by_file(violations).each do |file, by_type|
            sections << "## #{file}\n"
            by_type.each do |type, type_violations|
              sections << format_type_section(type, type_violations)
            end
          end
        end
        sections.join("\n") + "\n"
      end

      def header(violations)
        files_touched = violations.map(&:file).uniq.length
        <<~MD
          # Guardrails audit — suggestions

          Generated #{@now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}

          - **Total violations:** #{violations.length}
          - **Files touched:** #{files_touched}

          ---
        MD
      end

      def group_by_file(violations)
        violations
          .group_by(&:file)
          .transform_values { |vs| vs.group_by(&:type) }
      end

      def format_type_section(type, violations)
        suggestion = SUGGESTIONS.fetch(type) do
          { rule: "Review this violation.", replacement: "" }
        end
        lines = ["### #{type} (#{violations.length})\n"]
        violations.each do |v|
          lines << "- [ ] **Line #{v.line}, col #{v.column}:** `#{v.snippet}`"
          lines << "  - **Rule:** #{suggestion[:rule]}"

          match = visible_match(v)
          replacement_text = helper_specific_replacement(v) || suggestion[:replacement]

          if match
            lines << format_match_line(v, match)
          elsif !replacement_text.empty?
            lines << "  - **Suggested replacement:** #{replacement_text}"
          end
        end
        lines.join("\n") + "\n"
      end

      def build_matchers(tokens, threshold)
        COMPATIBLE_SYNTAX.transform_values do |syntaxes|
          # Order tokens so syntaxes earlier in the list act as fallbacks
          # and later syntaxes win on lookup-key collision (Hash#[]=
          # overwrites in iteration order).
          ordered = syntaxes.flat_map { |syn| tokens.select { |t| t.syntax == syn } }
          TokenMatcher.new(ordered, near_match_threshold: threshold)
        end
      end

      def visible_match(violation)
        matcher = @matchers[violation.type]
        return nil unless matcher

        match = matcher.match(violation.value)
        return nil unless match
        return nil if match.kind == :near && @near_match_policy == "leave"

        match
      end

      def helper_specific_replacement(violation)
        return nil unless violation.type == :helper_recommended

        HELPER_REPLACEMENTS[violation.value]
      end

      def format_match_line(violation, match)
        token = match.token
        ref = format_token_reference(violation, token)
        defined_at = "#{token.file}:#{token.line}"
        if match.kind == :exact
          "  - **Suggested replacement:** Use `#{ref}` (matches token `#{token.name}` defined in `#{defined_at}`)."
        else
          "  - **Suggested replacement (near match, channel diff #{match.distance}):** Use `#{ref}` " \
            "(close to token `#{token.name}` = `#{token.value}` in `#{defined_at}`)."
        end
      end

      def format_token_reference(violation, token)
        case token.syntax
        when :css_var then "var(--#{token.name})"
        when :scss_var then "$#{token.name}"
        when :tailwind then tailwind_utility_for(violation, token)
        else token.name
        end
      end

      # Pulls the utility prefix out of the violation's snippet (e.g. `bg`
      # from `class="bg-[#0066ff]"`) and joins it with the token name. Falls
      # back to the bare token name when we can't recover the prefix.
      def tailwind_utility_for(violation, token)
        return token.name unless violation && violation.snippet

        match = violation.snippet.match(/(\w[\w-]*)-\[#{Regexp.escape(violation.value)}\]/)
        match ? "#{match[1]}-#{token.name}" : token.name
      end
    end
  end
end
