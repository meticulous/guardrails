# frozen_string_literal: true

require "io/console"
require_relative "../guardrails"
require_relative "report/style"
require_relative "report/html"
require_relative "tui/state"
require_relative "tui/screen"
require_relative "tui/keys"
require_relative "tui/editor"

module Guardrails
  # Interactive browser for an audit run: a severity roll-up you can
  # drill into (category → finding → location), regroup by file,
  # filter, and jump from into your editor or the HTML report.
  #
  # This class owns the terminal and nothing else — raw mode, the
  # alternate screen, the read-key/redraw loop, and the side effects
  # a key can ask for. Navigation lives in TUI::State, drawing in
  # TUI::Screen, key decoding in TUI::Keys; each is testable without
  # a terminal, which this file is not.
  #
  # Built on io/console alone. A list with drill-down doesn't need a
  # widget toolkit, and the gem's dependency list stays at two.
  class TUI
    class NotInteractive < Guardrails::Error; end

    ENTER_SCREEN = "\e[?1049h\e[?25l"  # alternate screen, hide cursor
    LEAVE_SCREEN = "\e[?25h\e[?1049l"
    RESIZE_POLL = 0.25

    # `runner` is a callable returning a finished Report::Run. It's a
    # callable rather than a Run so `r` can re-run the audit with the
    # same options the task was started with.
    def initialize(runner:, root:, input: $stdin, output: $stdout, env: ENV)
      @runner = runner
      @root = root
      @input = input
      @output = output
      @env = env
      @sources = {}
    end

    def start
      unless @input.respond_to?(:tty?) && @input.tty? && @output.tty?
        raise NotInteractive, "guardrails:tui needs an interactive terminal. " \
                              "Use guardrails:audit (or FORMAT=json / FORMAT=html) when piping or in CI."
      end

      @output.puts "Running Guardrails audit…"
      @run = @runner.call
      @state = State.new(categories: @run.categories)
      @keys = Keys.new(@input)
      with_terminal { event_loop }
    end

    private

    def event_loop
      draw
      loop do
        key = @keys.next(timeout: RESIZE_POLL)
        if key.nil?
          draw if resized?
          next
        end
        break if key == :eof || perform(@state.handle(key)) == :quit

        draw
      end
    end

    def perform(action)
      kind, payload = action
      case kind
      when :quit then :quit
      when :edit then open_editor(payload)
      when :web then open_web_report
      when :rerun then rerun
      end
    end

    def open_editor(location)
      command = Editor.command(location, root: @root, env: @env)
      return @state.notice = "No editor found — set $EDITOR (or $GUARDRAILS_EDITOR)." unless command

      ok = Editor.terminal?(command) ? suspended { system(*command) } : system(*command, out: File::NULL, err: File::NULL)
      @state.notice = ok ? "Opened #{location}" : "Couldn't run #{command.first} — check $EDITOR."
      @sources.clear # the file may have just been edited
    end

    def open_web_report
      path = Report::Html.new(categories: @run.categories, root: @root, muted: @run.muted_severities).write
      opener = Editor.opener(path.to_s)
      opened = opener && system(*opener, out: File::NULL, err: File::NULL)
      @state.notice = "#{opened ? 'Opened' : 'Wrote'} #{path.relative_path_from(Pathname(@root).expand_path)}"
    rescue SystemCallError => e
      @state.notice = "Couldn't write the report: #{e.message}"
    end

    def rerun
      @state.notice = "Running audit…"
      draw
      @run = @runner.call
      @sources.clear
      @state.replace(categories: @run.categories)
      @state.notice = "Audit re-run."
    end

    # ---- terminal ---------------------------------------------------

    def draw
      rows, columns = size
      @drawn_size = [rows, columns]
      lines = Screen.new(state: @state, root: @root, width: columns, height: rows,
                         color: Report::Style.new(io: @output).color?, sources: @sources).lines
      # \e[K after each line clears leftovers from a longer previous
      # frame; \r\n because raw mode doesn't translate newlines.
      @output.write("\e[H#{lines.map { |line| "#{line}\e[K" }.join("\r\n")}\e[J")
      @output.flush
    end

    def size
      rows, columns = @output.winsize
      rows.to_i.positive? && columns.to_i.positive? ? [rows, columns] : [24, 80]
    rescue SystemCallError, NotImplementedError
      [24, 80]
    end

    def resized?
      size != @drawn_size
    end

    def with_terminal
      @input.raw do
        @output.write(ENTER_SCREEN)
        yield
      ensure
        @output.write(LEAVE_SCREEN)
        @output.flush
      end
    end

    # Hand the terminal to a child process (a terminal editor), then
    # take it back.
    def suspended
      @output.write(LEAVE_SCREEN)
      @output.flush
      @input.cooked { yield }
    ensure
      @output.write(ENTER_SCREEN)
    end
  end
end
