# frozen_string_literal: true

require_relative "../report/finding"
require_relative "../report/summary"

module Guardrails
  class TUI
    # Everything the TUI knows that isn't pixels: which screen you're
    # on, where the cursor is, the active filter and grouping. Keys go
    # in through `handle`, which returns an action for the main loop
    # when the key asks for something State can't do itself (open an
    # editor, write the web report, re-run the audit, quit).
    #
    # No terminal I/O in here — that's what makes the navigation
    # logic testable without a PTY.
    class State
      # One line in a list. `:header` rows group items and are skipped
      # by the cursor; `:item` rows are selectable and carry a payload
      # (category name, file path, Finding, or Location).
      Row = Struct.new(:kind, :label, :meta, :severity, :payload, :flag, keyword_init: true) do
        def selectable?
          kind == :item
        end
      end

      # A screen in the drill-down stack.
      #   :rollup   — categories grouped by severity      (root, by category)
      #   :files    — files ranked by finding count       (root, by file)
      #   :findings — findings within one category / file
      #   :detail   — one finding; rows are its locations
      Frame = Struct.new(:kind, :title, :scope, :cursor, :scroll, keyword_init: true)

      GROUPINGS = %i[category file].freeze
      NO_FILE = "(no file)"

      attr_reader :grouping, :filter, :mode
      attr_accessor :notice, :page_size

      def initialize(categories:)
        @grouping = :category
        @filter = +""
        @mode = :normal
        @help = false
        @page_size = 10
        replace(categories: categories)
      end

      # Swap in fresh audit results (initial load and re-run). Grouping
      # and filter survive; the drill-down stack doesn't, since the
      # finding you were looking at may no longer exist.
      def replace(categories:)
        @categories = categories
        @rows_cache = {}.compare_by_identity
        reset_frames
      end

      def frame
        @frames.last
      end

      def depth
        @frames.length
      end

      def help?
        @help
      end

      def filtering?
        @mode == :filter
      end

      def breadcrumb
        @frames.map(&:title)
      end

      def rows
        @rows_cache[frame] ||= build_rows(frame)
      end

      def selected_row
        frame.cursor && rows[frame.cursor]
      end

      # The finding the preview pane should describe: the highlighted
      # row on a findings list, or the finding a detail screen is for.
      def selected_finding
        case frame.kind
        when :findings then selected_row&.payload
        when :detail then frame.scope
        end
      end

      def selected_location
        case frame.kind
        when :files then file_location(selected_row&.payload)
        when :findings then selected_location_in_list
        when :detail then selected_row&.payload
        end
      end

      def category_for(finding)
        @categories.find { |c| c.name == finding.category }
      end

      def visible_findings
        all = @categories.flat_map(&:findings)
        return all if @filter.empty?

        needle = @filter.downcase
        all.select { |f| haystack(f).include?(needle) }
      end

      def totals
        counts = visible_findings.group_by(&:severity).transform_values(&:length)
        Report::Summary::SEVERITY_ORDER.to_h { |s| [s, counts.fetch(s, 0)] }
      end

      def handle(key)
        @notice = nil
        if @help
          @help = false
          return nil
        end
        return handle_filter_key(key) if filtering?

        handle_normal_key(key)
      end

      private

      def handle_normal_key(key)
        case key
        when :up, "k" then move(-1)
        when :down, "j" then move(1)
        when :page_up then move(-@page_size)
        when :page_down, " " then move(@page_size)
        when :home, "g" then jump(:first)
        when :end, "G" then jump(:last)
        when :enter, :right, "l" then return drill_in
        when :escape, :left, "h", :backspace then back
        when :tab then toggle_grouping
        when "/" then @mode = :filter
        when "o" then return edit_action
        when "w" then return [:web]
        when "r" then return [:rerun]
        when "?" then @help = true
        when "q", :ctrl_c then return [:quit]
        end
        nil
      end

      def handle_filter_key(key)
        case key
        when :enter then @mode = :normal
        when :escape then apply_filter(+"", done: true)
        when :ctrl_c then return [:quit]
        when :backspace
          @filter.empty? ? @mode = :normal : apply_filter(@filter[0...-1])
        when String then apply_filter(@filter + key)
        end
        nil
      end

      # Filtering changes what every screen contains, so the stack
      # collapses to the root rather than leaving you inside a category
      # that may have just filtered down to nothing.
      def apply_filter(text, done: false)
        @filter = text
        @mode = :normal if done
        @rows_cache = {}.compare_by_identity
        reset_frames
      end

      def toggle_grouping
        @grouping = GROUPINGS[(GROUPINGS.index(@grouping) + 1) % GROUPINGS.length]
        reset_frames
      end

      def reset_frames
        root = if @grouping == :category
                 Frame.new(kind: :rollup, title: "All findings")
               else
                 Frame.new(kind: :files, title: "All files")
               end
        @frames = [root]
        place_cursor(root)
      end

      def drill_in
        row = selected_row
        return nil unless row

        case frame.kind
        when :rollup then push(Frame.new(kind: :findings, title: row.payload, scope: [:category, row.payload]))
        when :files then push(Frame.new(kind: :findings, title: row.payload, scope: [:file, row.payload]))
        when :findings then push(Frame.new(kind: :detail, title: short(row.payload.title), scope: row.payload))
        when :detail then return edit_action
        end
        nil
      end

      def back
        if @frames.length > 1
          @rows_cache.delete(@frames.pop)
        elsif !@filter.empty?
          apply_filter(+"")
        end
      end

      def push(new_frame)
        @frames << new_frame
        place_cursor(new_frame)
      end

      def edit_action
        location = selected_location
        if location
          [:edit, location]
        else
          @notice = frame.kind == :rollup ? "Open a category first — o works on a file or finding." : "Nothing to open — no file location here."
          nil
        end
      end

      def file_location(file)
        Report::Location.new(file: file) if file && file != NO_FILE
      end

      # On a file-scoped list, open the occurrence in *that* file, not
      # whichever location the finding happens to list first.
      def selected_location_in_list
        finding = selected_row&.payload
        return nil unless finding

        kind, value = frame.scope
        (kind == :file && finding.locations.find { |l| l.file == value }) || finding.location
      end

      def place_cursor(target)
        list = @rows_cache[target] ||= build_rows(target)
        target.cursor = list.index(&:selectable?)
        target.scroll = 0
      end

      def move(delta)
        return unless frame.cursor

        selectable = rows.each_index.select { |i| rows[i].selectable? }
        position = selectable.index(frame.cursor) || 0
        frame.cursor = selectable[(position + delta).clamp(0, selectable.length - 1)]
      end

      def jump(edge)
        selectable = rows.each_index.select { |i| rows[i].selectable? }
        frame.cursor = selectable.public_send(edge) unless selectable.empty?
      end

      def build_rows(target)
        case target.kind
        when :rollup then rollup_rows
        when :files then file_rows
        when :findings then finding_rows(target.scope)
        when :detail then location_rows(target.scope)
        end
      end

      def rollup_rows
        by_category = visible_findings.group_by(&:category)
        visible = @categories.select { |c| by_category.key?(c.name) }

        Report::Summary::SEVERITY_ORDER.flat_map do |severity|
          group = visible.select { |c| c.severity == severity }
          next [] if group.empty?

          total = group.sum { |c| by_category[c.name].length }
          header = Row.new(kind: :header, severity: severity,
                           label: "#{pluralize(group.length, 'category', 'categories')}, #{pluralize(total, 'finding')}")
          items = group.sort_by { |c| -by_category[c.name].length }.map do |c|
            Row.new(kind: :item, label: c.name, severity: severity, payload: c.name,
                    meta: pluralize(by_category[c.name].length, "finding"),
                    flag: c.auto_fix ? "auto-fix" : nil)
          end
          [header, *items]
        end
      end

      # A finding spanning several files counts once in each of them —
      # from a file's point of view, it has that problem.
      def file_rows
        by_file = Hash.new { |h, k| h[k] = [] }
        visible_findings.each do |finding|
          files = finding.files
          (files.empty? ? [NO_FILE] : files).each { |file| by_file[file] << finding }
        end

        by_file.sort_by { |file, list| [-list.length, file] }.map do |file, list|
          Row.new(kind: :item, label: file, payload: file, severity: worst_severity(list),
                  meta: pluralize(list.length, "finding"))
        end
      end

      def finding_rows(scope)
        kind, value = scope
        list = visible_findings.select do |f|
          if kind == :category then f.category == value
          elsif value == NO_FILE then f.files.empty?
          else f.files.include?(value)
          end
        end

        list.map do |finding|
          Row.new(kind: :item, label: finding.title, severity: finding.severity, payload: finding,
                  meta: kind == :file ? file_scoped_meta(finding, value) : location_meta(finding),
                  # Within a category the rollup row already said so.
                  flag: kind == :file && finding.auto_fix ? "auto-fix" : nil)
        end
      end

      def location_rows(finding)
        finding.locations.map do |location|
          Row.new(kind: :item, label: location.to_s, payload: location, severity: finding.severity)
        end
      end

      def location_meta(finding)
        case finding.locations.length
        when 0 then ""
        when 1 then finding.location.to_s
        else "#{finding.locations.length} locations"
        end
      end

      def file_scoped_meta(finding, file)
        lines = finding.locations.select { |l| l.file == file }.map(&:line).compact
        lines.empty? ? finding.category : "#{finding.category} · line #{lines.first(3).join(', ')}#{lines.length > 3 ? '…' : ''}"
      end

      def worst_severity(findings)
        Report::Summary::SEVERITY_ORDER.find { |s| findings.any? { |f| f.severity == s } }
      end

      def haystack(finding)
        [finding.category, finding.title, finding.suggestion, *finding.files].compact.join("\n").downcase
      end

      def pluralize(count, singular, plural = "#{singular}s")
        "#{count} #{count == 1 ? singular : plural}"
      end

      def short(text, limit = 40)
        text.length <= limit ? text : "#{text[0, limit - 1]}…"
      end
    end
  end
end
