# frozen_string_literal: true

require "pathname"

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
        }
      }.freeze

      def initialize(root, output: $stdout, now: Time.now)
        @root = Pathname(root)
        @output = output
        @now = now
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
          lines << "  - **Suggested replacement:** #{suggestion[:replacement]}" unless suggestion[:replacement].empty?
        end
        lines.join("\n") + "\n"
      end
    end
  end
end
