# frozen_string_literal: true

require_relative "style"

module Guardrails
  module Report
    # Top-of-report triage view. Builds a grouped severity rollup from
    # the audit's per-detector counts, so the reader sees the shape of
    # the findings before scrolling through the per-section detail.
    #
    # Each detector contributes one Entry. The rake task assembles the
    # full list after running its sub-audits and hands it to Summary.
    # Detector logic isn't aware of the report; Summary doesn't know
    # about specific detectors. That decoupling matters when we add
    # new detectors — they only need to register an Entry.
    class Summary
      # Severity order in the report: errors first (urgent), warnings
      # next (probably-fix), suggestions last (consider).
      SEVERITY_ORDER = %i[error warning suggestion].freeze

      Entry = Struct.new(:category, :count, :severity, :unit, :action, :auto_fix,
                         keyword_init: true) do
        # `unit` is the noun shown after the count: "findings",
        # "candidates", "groups", "clusters" — each detector picks
        # what reads naturally. Defaults to "findings".
        def unit
          self[:unit] || "findings"
        end
      end

      def initialize(entries:, output:, style: nil)
        @entries = entries.reject { |e| e.count.zero? }
        @output = output
        @style = style || Style.new(io: output)
      end

      def render(recap: false)
        return if @entries.empty?

        @output.puts ""
        @output.puts header_line(recap: recap)
        @output.puts ""

        SEVERITY_ORDER.each do |severity|
          group = @entries.select { |e| e.severity == severity }
          next if group.empty?

          render_severity_group(severity, group)
        end

        @output.puts divider
      end

      private

      def header_line(recap: false)
        kind = recap ? "recap" : "audit"
        title = "Guardrails #{kind}  —  #{total_findings} #{total_findings == 1 ? "finding" : "findings"}"
        bar = "═" * 3
        bar_plain = "=" * 3
        # The divider character tracks the color setting so an
        # ANSI-stripped pipe stays ASCII-only.
        bar_used = @style.color? ? bar : bar_plain
        rest = (@style.color? ? "═" : "=") * [70 - title.length - bar_used.length - 4, 4].max

        "#{@style.colorize(bar_used + ' ', :bold)}" \
          "#{@style.colorize(title, :bold)} " \
          "#{@style.colorize(rest, :dim)}"
      end

      def render_severity_group(severity, entries)
        total = entries.sum(&:count)
        @output.puts "  #{@style.section_heading(severity, "#{entries.length} #{entries.length == 1 ? "category" : "categories"}, #{total} #{total == 1 ? "finding" : "findings"}")}"

        entries.sort_by { |e| -e.count }.each do |entry|
          render_entry(entry)
        end
        @output.puts ""
      end

      def render_entry(entry)
        name = entry.category.ljust(32)
        unit = entry.unit
        unit = unit.sub(/s\z/, "") if entry.count == 1 && unit.end_with?("s")
        count_str = "#{entry.count.to_s.rjust(4)} #{unit}".ljust(22)
        flags = []
        flags << @style.colorize("[auto-fix available]", :green) if entry.auto_fix
        flags << @style.colorize(entry.action, :dim) if entry.action && !entry.auto_fix

        line = "    #{name}#{count_str}#{flags.join(' ')}".rstrip
        @output.puts line
      end

      def divider
        char = @style.color? ? "═" : "="
        @style.colorize(char * 75, :dim)
      end

      def total_findings
        @entries.sum(&:count)
      end
    end
  end
end
