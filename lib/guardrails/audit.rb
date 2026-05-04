# frozen_string_literal: true

require "pathname"

module Guardrails
  class Audit
    Violation = Struct.new(:type, :file, :line, :column, :snippet, keyword_init: true)

    SCAN_PATTERNS = [
      "app/views/**/*.html.erb",
      "app/components/**/*.html.erb"
    ].freeze

    INLINE_STYLE_PATTERN = /\bstyle\s*=\s*["'][^"']+["']/
    ERB_BLOCK_PATTERN = /<%[\s\S]*?%>/

    def initialize(root:, output: $stdout)
      @root = Pathname(root)
      @output = output
    end

    def run
      violations = collect_files.flat_map { |file| scan_file(file) }
      print_report(violations)
      violations
    end

    private

    def collect_files
      SCAN_PATTERNS
        .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
        .map { |path| Pathname(path) }
        .uniq
    end

    def scan_file(file)
      content = file.read
      masked = mask_erb(content)
      original_lines = content.lines

      violations = []
      masked.each_line.with_index do |line, idx|
        line.scan(INLINE_STYLE_PATTERN) do
          column = Regexp.last_match.begin(0) + 1
          violations << Violation.new(
            type: :inline_style,
            file: file.relative_path_from(@root).to_s,
            line: idx + 1,
            column: column,
            snippet: original_lines[idx]&.chomp&.strip
          )
        end
      end
      violations
    end

    def mask_erb(content)
      content.gsub(ERB_BLOCK_PATTERN) do |match|
        newline_count = match.count("\n")
        "\n" * newline_count + " " * (match.length - newline_count)
      end
    end

    def print_report(violations)
      if violations.empty?
        @output.puts "Guardrails audit: no violations found."
        return
      end

      noun = violations.length == 1 ? "violation" : "violations"
      @output.puts "Guardrails audit: #{violations.length} #{noun} found"
      violations.each do |v|
        @output.puts "  [#{v.type}] #{v.file}:#{v.line}:#{v.column}"
        @output.puts "    #{v.snippet}"
      end
    end
  end
end
