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

      # Per-violation-type token compatibility for *suggestions*, expressed
      # as an ordered list of matcher layers. The first layer that produces
      # any match (exact or near) wins, so the preferred substitute syntax
      # is genuinely preferred even on tied near matches. tailwind_arbitrary
      # tries :tailwind utility names first; if no theme entry matches, it
      # falls back to :css_var (parameterized arbitrary `bg-[var(--name)]`).
      COMPATIBLE_SYNTAX = {
        raw_color: [[:css_var]],
        tailwind_arbitrary: [[:tailwind], [:css_var]]
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
        COMPATIBLE_SYNTAX.transform_values do |layers|
          layers.map do |syntaxes|
            subset = tokens.select { |t| syntaxes.include?(t.syntax) }
            TokenMatcher.new(subset, near_match_threshold: threshold)
          end
        end
      end

      def visible_match(violation)
        matchers = @matchers[violation.type]
        return nil unless matchers

        matchers.each do |matcher|
          match = matcher.match(violation.value)
          next unless match
          next if match.kind == :near && @near_match_policy == "leave"

          return match
        end
        nil
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
        when :css_var
          # For tailwind_arbitrary, the only valid replacement that stays
          # inside class="..." is another arbitrary value. Wrap the var()
          # in the original utility prefix so the suggestion is something
          # the user can actually paste in.
          if violation && violation.type == :tailwind_arbitrary
            tailwind_arbitrary_with_var(violation, token)
          else
            "var(--#{token.name})"
          end
        when :scss_var then "$#{token.name}"
        when :tailwind then tailwind_utility_for(violation, token)
        else token.name
        end
      end

      # Capture the *full* utility prefix (including any chained variants
      # like `lg:hover:` or `[&>div]:`) from the violation's snippet, then
      # append the token name. Greedy `[^\s"'`]+` followed by `-[value]`
      # backtracks until the bracket boundary, so it reaches all the way to
      # the start of the variant chain. Falls back to the bare token name
      # if the snippet doesn't contain the original arbitrary value.
      def tailwind_utility_for(violation, token)
        return token.name unless violation && violation.snippet

        prefix = extract_tailwind_prefix(violation)
        prefix ? "#{prefix}-#{token.name}" : token.name
      end

      def tailwind_arbitrary_with_var(violation, token)
        prefix = extract_tailwind_prefix(violation)
        prefix ? "#{prefix}-[var(--#{token.name})]" : "var(--#{token.name})"
      end

      def extract_tailwind_prefix(violation)
        return nil unless violation.snippet && violation.value

        # `[^\s"'`]+` is greedy, so for `class="lg:hover:bg-[#0066ff]"` the
        # engine backtracks until `-[#0066ff]` matches and the capture
        # lands on the full `lg:hover:bg`.
        match = violation.snippet.match(/([^\s"'`]+)-\[#{Regexp.escape(violation.value)}\]/)
        match ? match[1] : nil
      end
    end
  end
end
