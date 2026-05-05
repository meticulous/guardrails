# frozen_string_literal: true

module Guardrails
  class Init
    # Minimal stdin/stdout prompter for guardrails:init. When the input
    # stream isn't a TTY (CI, piped invocations) every method short-circuits
    # to the configured default — no blocking reads, no surprises.
    class Prompter
      def initialize(input: $stdin, output: $stdout)
        @input = input
        @output = output
      end

      # Free-text prompt. Empty input accepts the default.
      def ask(question, default:)
        return default unless interactive?

        @output.print "#{question} [#{default}]: "
        @output.flush if @output.respond_to?(:flush)
        line = @input.gets
        return default if line.nil?

        answer = line.chomp.strip
        answer.empty? ? default : answer
      end

      # Choose one of `choices` (Strings). Accepts the choice name itself or
      # its 1-based index. Re-prompts on bad input. Empty input accepts
      # `default`.
      def choose(question, choices:, default:)
        return default unless interactive?

        loop do
          @output.puts question
          choices.each_with_index do |c, i|
            marker = c == default ? "*" : " "
            @output.puts "  #{i + 1}) #{c}#{marker == '*' ? ' (default)' : ''}"
          end
          @output.print "> "
          @output.flush if @output.respond_to?(:flush)
          line = @input.gets
          return default if line.nil?

          raw = line.chomp.strip
          return default if raw.empty?
          return choices[raw.to_i - 1] if raw.match?(/\A\d+\z/) && (1..choices.length).cover?(raw.to_i)
          return raw if choices.include?(raw)

          @output.puts "  -> '#{raw}' isn't one of #{choices.join(', ')}; try again."
        end
      end

      private

      def interactive?
        @input.respond_to?(:tty?) && @input.tty?
      end
    end
  end
end
