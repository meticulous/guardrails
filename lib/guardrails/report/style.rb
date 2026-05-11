# frozen_string_literal: true

module Guardrails
  module Report
    # ANSI styling for the text audit report. Three rules:
    #
    #   1. Colors only when the output is a real terminal (TTY check).
    #      Piping to a file or `tee` produces plain text.
    #   2. `NO_COLOR=1` always wins. (https://no-color.org/ convention.)
    #   3. Tests pass a non-TTY StringIO and get plain output by default
    #      — no need to scrub ANSI sequences out of every expectation.
    #
    # Callers don't decide whether to colorize; they just call
    # `Style.severity(:error, "raw_color")` and the style instance
    # quietly emits ANSI or plain text based on those rules.
    class Style
      # Foreground codes, kept small. Bold + dim are modifiers, not
      # colors — combined where we want emphasis without screaming.
      ANSI = {
        reset: "\e[0m",
        bold: "\e[1m",
        dim: "\e[2m",
        red: "\e[31m",
        yellow: "\e[33m",
        green: "\e[32m",
        cyan: "\e[36m",
        blue: "\e[34m",
        magenta: "\e[35m"
      }.freeze

      # Severity → (glyph, color) tuple. Glyphs are ASCII so they
      # render in any terminal; we don't use emoji or box-drawing
      # for the per-line tags. The summary box uses light box-drawing
      # characters separately, with an ASCII fallback for terminals
      # that mangle them (rare in 2026 but possible over SSH/PTY).
      SEVERITY_FORMAT = {
        error: { glyph: "x", color: :red, label: "ERROR" },
        warning: { glyph: "!", color: :yellow, label: "WARNING" },
        suggestion: { glyph: "i", color: :cyan, label: "SUGGEST" }
      }.freeze

      def initialize(io: $stdout, force: nil, no_color: nil)
        @io = io
        @force = force
        @no_color = no_color
      end

      # True when we should emit ANSI sequences. Tests pass force:
      # true/false to bypass auto-detection.
      def color?
        return @force unless @force.nil?
        return false if no_color_env?

        @io.respond_to?(:tty?) && @io.tty?
      end

      # Wrap text in an ANSI color code if `color?`, else return
      # unchanged. `style` can be a single key or array (e.g.
      # `[:bold, :red]`) — codes concatenate.
      def colorize(text, style)
        return text unless color?

        codes = Array(style).map { |k| ANSI.fetch(k) }.join
        "#{codes}#{text}#{ANSI[:reset]}"
      end

      # Tag a finding line with its severity. Output shape:
      #
      #   [error]   raw_color
      #   [warning] helper_recommended
      #   [suggest] pattern
      #
      # Padding aligns the brackets so columns line up across the
      # report. Colorized form bolds the bracket+label.
      def severity(level, category)
        format = SEVERITY_FORMAT.fetch(level)
        tag = "[#{format[:label].downcase}]".ljust(10)
        "#{colorize(tag, [:bold, format[:color]])} #{category}"
      end

      # Section heading — bolded category label with a colored
      # severity glyph in front. Used for the per-detector section
      # intro: `x ERROR — raw_color (82 findings)`.
      def section_heading(level, title)
        format = SEVERITY_FORMAT.fetch(level)
        glyph = colorize(format[:glyph], [:bold, format[:color]])
        "#{glyph} #{colorize(format[:label], [:bold, format[:color]])} #{colorize("—", :dim)} #{colorize(title, :bold)}"
      end

      # File:line:col, in dim so it recedes when the content next to
      # it is what matters. Returns plain text when colors are off.
      def location(path)
        colorize(path, :dim)
      end

      # Inline suggestion arrow. Always rendered the same way so the
      # eye learns it: `→ <action>`. Cyan so it stands out from the
      # finding line without competing with the severity color.
      def suggestion(text)
        "#{colorize("→", :cyan)} #{text}"
      end

      # Box-drawing characters for the top-of-report summary header.
      # Falls back to ASCII (`+ - |`) when colors are off, since
      # both behaviors track the same TTY/NO_COLOR signal.
      def box_chars
        if color?
          { tl: "╭", tr: "╮", bl: "╰", br: "╯", h: "─", v: "│", t: "├", b: "┤" }
        else
          { tl: "+", tr: "+", bl: "+", br: "+", h: "-", v: "|", t: "+", b: "+" }
        end
      end

      private

      def no_color_env?
        return @no_color unless @no_color.nil?

        # Per https://no-color.org/: ANY value (even empty) disables color.
        ENV.key?("NO_COLOR")
      end
    end
  end
end
