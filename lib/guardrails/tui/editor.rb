# frozen_string_literal: true

require "shellwords"
require "rbconfig"

module Guardrails
  class TUI
    # Builds the command that opens a Report::Location in the user's
    # editor, at the right line when the editor has a way to say so.
    #
    # Editor choice: $GUARDRAILS_EDITOR, then $VISUAL, then $EDITOR;
    # with none set, the OS opener (`open` / `xdg-open`), which loses
    # the line number but still gets you to the file.
    #
    # Always returns an argv array (never a shell string) — paths come
    # from the audited project's filenames, and they go nowhere near a
    # shell.
    module Editor
      # file:line:col as one argument, behind a --goto flag.
      GOTO_FLAG = %w[code code-insiders codium cursor windsurf].freeze
      # file:line:col as one bare argument.
      COLON_SUFFIX = %w[zed subl sublime_text hx].freeze
      # +line before the file.
      PLUS_LINE = %w[vi vim nvim nano emacs emacsclient micro kak].freeze
      # --line N before the file.
      LINE_FLAG = %w[rubymine idea mine].freeze

      # `code --wait` is the usual $EDITOR value for git's benefit. Here
      # it would freeze the TUI until the editor tab closes.
      WAIT_FLAGS = %w[--wait -w -W].freeze
      TERMINAL_EDITORS = (PLUS_LINE + %w[hx]).freeze

      module_function

      def command(location, root:, env: ENV, host_os: RbConfig::CONFIG["host_os"])
        path = File.join(root.to_s, location.file)
        editor = [env["GUARDRAILS_EDITOR"], env["VISUAL"], env["EDITOR"]].find { |v| v && !v.strip.empty? }
        return opener(path, host_os) unless editor

        parts = Shellwords.split(editor)
        name = File.basename(parts.first)
        parts -= WAIT_FLAGS unless TERMINAL_EDITORS.include?(name)
        parts + target_args(name, path, location)
      end

      # Terminal editors need the TUI to get out of the way (leave the
      # alternate screen, restore cooked mode) while they run.
      def terminal?(command)
        TERMINAL_EDITORS.include?(File.basename(command.first))
      end

      def opener(path, host_os = RbConfig::CONFIG["host_os"])
        case host_os
        when /darwin/ then ["open", path]
        when /linux|bsd/ then ["xdg-open", path]
        end
      end

      def target_args(name, path, location)
        position = [path, location.line, location.line && location.column].compact.join(":")
        if GOTO_FLAG.include?(name) then ["--goto", position]
        elsif COLON_SUFFIX.include?(name) then [position]
        elsif name == "mate" then location.line ? ["-l", location.line.to_s, path] : [path]
        elsif PLUS_LINE.include?(name) then location.line ? ["+#{location.line}", path] : [path]
        elsif LINE_FLAG.include?(name) then location.line ? ["--line", location.line.to_s, path] : [path]
        else [path]
        end
      end
    end
  end
end
