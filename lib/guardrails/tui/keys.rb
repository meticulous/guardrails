# frozen_string_literal: true

module Guardrails
  class TUI
    # Turns raw terminal bytes into key events: symbols for named keys
    # (:up, :enter, :escape, …), one-character strings for printable
    # input.
    #
    # Reads with read_nonblock into its own buffer rather than
    # getc/getch. Arrow keys arrive as a multi-byte escape sequence,
    # and telling a lone Esc from the start of one needs a "is more
    # coming?" check — which IO.select can't answer correctly if Ruby's
    # buffered reader has already swallowed the rest of the sequence.
    class Keys
      ESCAPE_SEQUENCES = {
        "[A" => :up, "[B" => :down, "[C" => :right, "[D" => :left,
        "OA" => :up, "OB" => :down, "OC" => :right, "OD" => :left,
        "[H" => :home, "[F" => :end, "OH" => :home, "OF" => :end,
        "[1~" => :home, "[4~" => :end, "[7~" => :home, "[8~" => :end,
        "[5~" => :page_up, "[6~" => :page_down, "[Z" => :tab
      }.freeze

      CONTROL = {
        "\r" => :enter, "\n" => :enter, "\t" => :tab,
        "\x7F" => :backspace, "\b" => :backspace, "\x03" => :ctrl_c
      }.freeze

      # How long a lone Esc waits for the rest of a sequence before
      # it's taken at face value. Long enough for a slow SSH hop,
      # short enough that Esc-to-go-back doesn't feel laggy.
      ESCAPE_TIMEOUT = 0.05

      def initialize(input)
        @input = input
        @buffer = +""
      end

      # Next key event; nil if `timeout` seconds pass with no input
      # (the main loop uses the nil to notice terminal resizes); :eof
      # once the input has hung up.
      def next(timeout: nil)
        fill(timeout) if @buffer.empty?
        return :eof if @eof && @buffer.empty?
        return nil if @buffer.empty?

        fill(ESCAPE_TIMEOUT) if @buffer == "\e"
        parse
      end

      private

      def parse
        return parse_escape if @buffer.start_with?("\e")

        char = @buffer.slice!(0)
        CONTROL.fetch(char) { char.match?(/[[:print:]]/) ? char : :unknown }
      end

      def parse_escape
        rest = @buffer[1..]
        sequence = ESCAPE_SEQUENCES.keys.find { |s| rest.start_with?(s) }
        if sequence
          @buffer.slice!(0, 1 + sequence.length)
          ESCAPE_SEQUENCES[sequence]
        elsif rest.empty?
          @buffer.clear
          :escape
        else
          # Unrecognized sequence (function key, mouse report, paste
          # bracket): drop all of it rather than leaking its tail into
          # the filter box as literal characters.
          @buffer.clear
          :unknown
        end
      end

      def fill(timeout)
        return unless ready?(timeout)

        chunk = @input.read_nonblock(256, exception: false)
        return if chunk == :wait_readable

        # A selectable input that reads nil has hung up (terminal
        # closed). Surface it so the main loop exits instead of spinning.
        return @eof = true if chunk.nil?

        @buffer << chunk.dup.force_encoding(Encoding::UTF_8).scrub("")
      end

      # StringIO (specs) has no file descriptor to select on; it's
      # "ready" whenever it has bytes left.
      def ready?(timeout)
        return !@input.eof? unless @input.respond_to?(:fileno) && @input.fileno

        !IO.select([@input], nil, nil, timeout).nil?
      rescue NotImplementedError
        !@input.eof?
      end
    end
  end
end
