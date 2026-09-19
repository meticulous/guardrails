# frozen_string_literal: true

require_relative "../report/style"

module Guardrails
  class TUI
    # Renders a State into exactly `height` terminal lines. Pure: takes
    # state and dimensions, returns strings, touches no terminal — the
    # main loop owns writing them out. (It does write `scroll` and
    # `page_size` back onto the state, since both depend on how tall
    # the list region turned out to be.)
    #
    # Layout, top to bottom:
    #
    #   title bar        totals by severity, grouping / filter
    #   breadcrumb       where you are in the drill-down
    #   ─────
    #   [info block]     detail screens only: title, suggestion, framing
    #   list             the rows State built for this frame
    #   ─────
    #   [preview]        findings + detail: source around the location
    #   ─────
    #   hints            keys for this screen, or the filter prompt
    class Screen
      ATTRIBUTES = { bold: 1, dim: 2, reverse: 7 }.freeze
      COLORS = { red: 31, green: 32, yellow: 33, cyan: 36 }.freeze
      SEVERITY = Report::Style::SEVERITY_FORMAT

      MAX_SOURCE_BYTES = 2 * 1024 * 1024

      HELP = [
        ["↑ ↓  j k", "move"],
        ["PgUp PgDn  space", "move a page"],
        ["g  G", "jump to top / bottom"],
        ["⏎  →  l", "open the highlighted row"],
        ["esc  ←  h", "go back (at the top level: clear the filter)"],
        ["tab", "switch grouping: by category ↔ by file"],
        ["/", "filter by category, title, suggestion, or file"],
        ["o", "open the highlighted location in your editor"],
        ["w", "write the HTML report and open it in a browser"],
        ["r", "re-run the audit"],
        ["q", "quit"]
      ].freeze

      def initialize(state:, root:, width:, height:, color: true, sources: {})
        @state = state
        @root = root.to_s
        @width = [width, 20].max
        @height = [height, 8].max
        @color = color
        @sources = sources
      end

      def lines
        body_height = @height - 5
        body = @state.help? ? help_lines : body_lines(body_height)
        body = body.first(body_height)
        body += [""] * (body_height - body.length)

        [title_bar, breadcrumb, rule, *body, rule(position_label), footer]
      end

      private

      # ---- chrome -----------------------------------------------------

      def title_bar
        totals = @state.totals
        left = [[" Guardrails", %i[bold]], ["  —  #{pluralize(totals.values.sum, 'finding')}   ", []]]
        totals.each do |severity, count|
          next if count.zero?

          format = SEVERITY.fetch(severity)
          left << ["#{format[:glyph]} #{count}  ", [:bold, format[:color]]]
        end
        right = @state.filter.empty? ? "by #{@state.grouping}" : "by #{@state.grouping} · filter: #{@state.filter}"
        justify(left, [[right, %i[dim]]])
      end

      def breadcrumb
        crumbs = @state.breadcrumb
        segments = [[" ", []]]
        crumbs.each_with_index do |crumb, i|
          segments << [" ▸ ", %i[dim]] unless i.zero?
          segments << [crumb, i == crumbs.length - 1 ? %i[bold] : %i[dim]]
        end
        compose(segments)
      end

      def rule(label = nil)
        return paint("─" * @width, :dim) if label.nil? || label.empty?

        tail = " #{label} ──"
        paint("#{'─' * [@width - tail.length, 0].max}#{tail}", :dim)
      end

      def position_label
        return nil if @state.help? || @state.frame.cursor.nil?

        selectable = @state.rows.each_index.select { |i| @state.rows[i].selectable? }
        "#{selectable.index(@state.frame.cursor).to_i + 1}/#{selectable.length}"
      end

      def footer
        if @state.filtering?
          compose([[" / ", %i[bold cyan]], [@state.filter, %i[bold]], ["█", %i[dim]],
                   ["   ⏎ keep   esc clear", %i[dim]]])
        elsif @state.notice
          compose([[" #{@state.notice}", %i[yellow]]])
        else
          compose([[" #{hints}", %i[dim]]])
        end
      end

      def hints
        case @state.frame.kind
        when :rollup, :files
          other = @state.grouping == :category ? "by file" : "by category"
          "↑↓ move  ⏎ open  tab #{other}  / filter  w web report  r re-run  ? help  q quit"
        when :findings
          "↑↓ move  ⏎ details  o editor  esc back  / filter  w web report  ? help  q quit"
        when :detail
          "↑↓ location  ⏎ open in editor  esc back  w web report  ? help  q quit"
        end
      end

      # ---- body -------------------------------------------------------

      def body_lines(height)
        return empty_lines if @state.rows.empty? && @state.frame.kind != :detail

        case @state.frame.kind
        when :findings then list_with_preview(height, [])
        when :detail then list_with_preview(height, info_block(height / 2))
        else list_lines(height)
        end
      end

      # Splits the body between the list and a source preview. The
      # preview is worth having only when there's room for context
      # around the line, so short terminals get the list alone.
      def list_with_preview(height, info)
        remaining = height - info.length
        preview_height = remaining >= 12 ? [remaining / 2, 14].min : 0
        list_height = remaining - preview_height - (preview_height.zero? ? 0 : 1)

        out = info + list_lines(list_height)
        out += [rule, *preview_lines(preview_height)] unless preview_height.zero?
        out
      end

      def list_lines(height)
        return [] if height <= 0

        @state.page_size = [height - 1, 1].max
        rows = @state.rows
        scroll = scroll_for(rows, height)
        visible = rows[scroll, height] || []
        out = visible.each_with_index.map { |row, i| row_line(row, selected: scroll + i == @state.frame.cursor) }
        out + [""] * (height - out.length)
      end

      def scroll_for(rows, height)
        frame = @state.frame
        cursor = frame.cursor || 0
        scroll = frame.scroll || 0
        scroll = cursor if cursor < scroll
        scroll = cursor - height + 1 if cursor >= scroll + height
        # Keep a leading header on screen when the cursor sits on the
        # first item beneath it.
        scroll = 0 if cursor < height && rows[0...cursor].none?(&:selectable?)
        frame.scroll = scroll.clamp(0, [rows.length - height, 0].max)
      end

      def row_line(row, selected:)
        return header_line(row) unless row.selectable?

        format = row.severity && SEVERITY.fetch(row.severity)
        marker = selected ? " › " : "   "
        glyph = format ? "#{format[:glyph]} " : ""
        right = [row.meta, row.flag && "[#{row.flag}]"].compact.reject(&:empty?).join("  ")

        if selected
          paint(plain_justified("#{marker}#{glyph}#{sanitize(row.label)}", right), :reverse, :bold)
        else
          justify(
            [[marker, []], [glyph, [:bold, format && format[:color]]], [sanitize(row.label), []]],
            [[right, %i[dim]]]
          )
        end
      end

      def header_line(row)
        format = SEVERITY.fetch(row.severity)
        compose([[" #{format[:glyph]} #{format[:label]}", [:bold, format[:color]]], [" — #{row.label}", %i[dim]]])
      end

      def empty_lines
        message = if @state.filter.empty?
                    ["✓ No findings — the audit is clean.", %i[green bold]]
                  else
                    ["No findings match “#{@state.filter}”. Esc clears the filter.", %i[dim]]
                  end
        ["", compose([["   ", []], message])]
      end

      def help_lines
        ["", compose([["   Keys", %i[bold]]]), ""] +
          HELP.map { |keys, what| compose([["   #{keys.ljust(20)}", %i[cyan]], [what, []]]) } +
          ["", compose([["   Editor: $GUARDRAILS_EDITOR, then $VISUAL, then $EDITOR.  Any key closes this.", %i[dim]]])]
      end

      # ---- detail info block --------------------------------------------

      def info_block(max_height)
        finding = @state.selected_finding
        format = SEVERITY.fetch(finding.severity)
        out = wrap(sanitize(finding.title), @width - 14).first(3).each_with_index.map do |text, i|
          tag = i.zero? ? "[#{format[:label].downcase}]".ljust(10) : " " * 10
          compose([["  ", []], [tag, [:bold, format[:color]]], [" #{text}", %i[bold]]])
        end
        wrap(finding.suggestion.to_s, @width - 6).first(3).each_with_index do |text, i|
          out << compose([[i.zero? ? "  → " : "    ", %i[cyan]], [sanitize(text), []]])
        end
        finding.details.each do |label, value|
          wrap("#{label}: #{sanitize(value.to_s)}", @width - 4).first(3).each { |text| out << compose([["  #{text}", []]]) }
        end
        framing = @state.category_for(finding)&.framing
        if framing
          out << ""
          wrap(framing, @width - 4).first(4).each { |text| out << compose([["  #{text}", %i[dim]]]) }
        end
        out << ""
        out << compose([[locations_heading(finding), %i[bold]]])
        out.last([max_height, 3].max)
      end

      def locations_heading(finding)
        count = finding.locations.length
        count.zero? ? "  No file locations for this finding." : "  #{pluralize(count, 'location')}"
      end

      # ---- source preview ---------------------------------------------

      def preview_lines(height)
        finding = @state.selected_finding
        location = @state.selected_location
        return [""] * height unless finding

        out = []
        if @state.frame.kind == :findings && finding.suggestion
          wrap(finding.suggestion, @width - 6).first(2).each_with_index do |text, i|
            out << compose([[i.zero? ? "  → " : "    ", %i[cyan]], [sanitize(text), []]])
          end
        end
        out << compose([["  #{location || 'no file location'}", %i[dim]]])
        out += source_lines(location, height - out.length) if location
        out.first(height) + [""] * [height - out.length, 0].max
      end

      def source_lines(location, height)
        return [] if height <= 0

        source = read_source(location.file)
        return [compose([["  (#{source})", %i[dim]]])] if source.is_a?(String)

        target = location.line
        first = target ? (target - (height / 2)).clamp(1, [source.length - height + 1, 1].max) : 1
        gutter = (first + height).to_s.length
        source[first - 1, height].to_a.each_with_index.map do |text, i|
          number = first + i
          hit = number == target
          compose([
            [hit ? "  ▸ " : "    ", %i[bold yellow]],
            ["#{number.to_s.rjust(gutter)} │ ", hit ? %i[bold] : %i[dim]],
            [sanitize(text), hit ? %i[bold] : []]
          ])
        end
      end

      # Array of lines, or a String explaining why there aren't any.
      def read_source(file)
        @sources[file] ||= begin
          path = File.join(@root, file)
          if !File.file?(path) then "file not found"
          elsif File.size(path) > MAX_SOURCE_BYTES then "file too large to preview"
          else
            raw = File.binread(path)
            raw.include?("\0") ? "binary file" : raw.force_encoding(Encoding::UTF_8).scrub("?").lines(chomp: true)
          end
        end
      end

      # ---- text plumbing ------------------------------------------------

      # File contents and snippets end up on screen verbatim, so strip
      # anything a terminal would act on rather than display — a view
      # containing a literal escape sequence mustn't be able to move
      # the cursor or recolor the UI.
      def sanitize(text)
        text.to_s.gsub("\t", "  ").gsub(/[[:cntrl:]]/, "")
      end

      def paint(text, *styles)
        codes = styles.flatten.compact.filter_map { |s| ATTRIBUTES[s] || (@color ? COLORS[s] : nil) }
        codes.empty? ? text : "\e[#{codes.join(';')}m#{text}\e[0m"
      end

      # Segments are [text, styles] pairs. Truncation happens on the
      # plain text *before* painting, so an ANSI sequence is never cut
      # in half and never counts toward the width.
      def compose(segments, width = @width)
        remaining = width
        segments.filter_map do |text, styles|
          next if remaining <= 0 || text.nil? || text.empty?

          text = "#{text[0, [remaining - 1, 0].max]}…" if text.length > remaining
          remaining -= text.length
          paint(text, *styles)
        end.join
      end

      # Left segments, then right segments flush against the right
      # edge. The right side wins when space is tight (it's the count /
      # location — the part you scan down), capped at 3/5 of the width.
      def justify(left, right)
        right_text = right.sum { |text, _| text.to_s.length }
        right_width = [right_text, @width * 3 / 5].min
        left_width = @width - right_width - 2
        left_text = left.sum { |text, _| text.to_s.length }
        gap = [@width - [left_text, left_width].min - right_width - 1, 1].max

        "#{compose(left, left_width)}#{' ' * gap}#{compose(right, right_width)}"
      end

      def plain_justified(left, right)
        right = truncate(right, @width * 3 / 5)
        left = truncate(left, @width - right.length - 2)
        "#{left}#{' ' * [@width - left.length - right.length - 1, 1].max}#{right} "
      end

      def truncate(text, limit)
        text.length <= limit ? text : "#{text[0, [limit - 1, 0].max]}…"
      end

      def wrap(text, width)
        width = [width, 10].max
        text.to_s.split(/\s+/).each_with_object([+""]) do |word, lines|
          if lines.last.empty? then lines.last << word
          elsif lines.last.length + 1 + word.length <= width then lines.last << " " << word
          else lines << +word
          end
        end.reject(&:empty?)
      end

      def pluralize(count, singular)
        "#{count} #{count == 1 ? singular : "#{singular}s"}"
      end
    end
  end
end
