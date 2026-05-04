# frozen_string_literal: true

require "pathname"
require "set"
require "stringio"

module Guardrails
  class Audit
    Violation = Struct.new(:type, :file, :line, :column, :snippet, :value, keyword_init: true)

    SCAN_PATTERNS = [
      "app/views/**/*.html.erb",
      "app/components/**/*.html.erb"
    ].freeze

    INLINE_STYLE_PATTERN = /\bstyle\s*=\s*["'][^"']+["']/
    INLINE_STYLE_DOUBLE = /\bstyle\s*=\s*"[^"]*"/
    INLINE_STYLE_SINGLE = /\bstyle\s*=\s*'[^']*'/
    ERB_BLOCK_PATTERN = /<%[\s\S]*?%>/
    HEX_LITERAL_PATTERN = /#[0-9a-fA-F]{3,8}\b/
    RGB_LITERAL_PATTERN = /\brgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+(?:\s*,\s*[\d.]+)?\s*\)/
    CLASS_ATTRIBUTE_DOUBLE = /\bclass\s*=\s*"([^"]*)"/
    CLASS_ATTRIBUTE_SINGLE = /\bclass\s*=\s*'([^']*)'/
    ARBITRARY_VALUE_PATTERN = /\[[^\]]+\]/

    def initialize(root:, output: $stdout, suggest: false, format: :text, apply: false)
      @root = Pathname(root)
      @output = output
      @suggest = suggest
      @format = format
      @apply = apply
    end

    def run
      violations = collect_files.flat_map { |file| scan_file(file) }
      print_report(violations)
      remaining = @apply ? apply_auto_fixes(violations) : violations
      write_suggestions(remaining) if @suggest
      remaining
    end

    private

    def collect_files
      SCAN_PATTERNS
        .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
        .map { |path| Pathname(path) }
        .uniq
    end

    def scan_file(file)
      content = File.read(file, encoding: Encoding::UTF_8)
      original_lines = content.lines
      masked_no_erb = mask(content, ERB_BLOCK_PATTERN)

      raw_color_input = mask_class_attributes(mask_inline_styles(masked_no_erb))

      detect_inline_styles(masked_no_erb, file, original_lines) +
        detect_raw_color_literals(raw_color_input, file, original_lines) +
        detect_tailwind_arbitrary(masked_no_erb, file, original_lines)
    end

    def detect_inline_styles(content, file, original_lines)
      scan_lines(content, INLINE_STYLE_PATTERN) do |idx, column, _line, match_text|
        Violation.new(
          type: :inline_style,
          file: relative(file),
          line: idx + 1,
          column: column,
          snippet: snippet(original_lines, idx),
          value: match_text
        )
      end
    end

    def detect_raw_color_literals(content, file, original_lines)
      violations = scan_lines(content, HEX_LITERAL_PATTERN) do |idx, column, line, match_text|
        next unless inside_quoted_attribute?(line, column - 1)

        Violation.new(
          type: :raw_color,
          file: relative(file),
          line: idx + 1,
          column: column,
          snippet: snippet(original_lines, idx),
          value: match_text
        )
      end
      violations += scan_lines(content, RGB_LITERAL_PATTERN) do |idx, column, line, match_text|
        next unless inside_quoted_attribute?(line, column - 1)

        Violation.new(
          type: :raw_color,
          file: relative(file),
          line: idx + 1,
          column: column,
          snippet: snippet(original_lines, idx),
          value: match_text
        )
      end
      violations
    end

    def detect_tailwind_arbitrary(content, file, original_lines)
      violations = []
      content.each_line.with_index do |line, idx|
        [CLASS_ATTRIBUTE_DOUBLE, CLASS_ATTRIBUTE_SINGLE].each do |attr_pattern|
          line.scan(attr_pattern) do
            outer = Regexp.last_match
            class_value = outer[1]
            value_start = outer.begin(1)

            class_value.scan(ARBITRARY_VALUE_PATTERN) do
              offset = Regexp.last_match.begin(0)
              bracket_match = Regexp.last_match[0]
              inner_value = bracket_match[1..-2] # strip [ and ]
              violations << Violation.new(
                type: :tailwind_arbitrary,
                file: relative(file),
                line: idx + 1,
                column: value_start + offset + 1,
                snippet: snippet(original_lines, idx),
                value: inner_value
              )
            end
          end
        end
      end
      violations
    end

    def scan_lines(content, pattern)
      violations = []
      content.each_line.with_index do |line, idx|
        line.scan(pattern) do
          m = Regexp.last_match
          column = m.begin(0) + 1
          violation = yield(idx, column, line, m[0])
          violations << violation if violation
        end
      end
      violations
    end

    def inside_quoted_attribute?(line, position)
      before = line[0...position]
      before.count('"').odd? || before.count("'").odd?
    end

    def mask(content, pattern)
      content.gsub(pattern) { |match| mask_chars(match) }
    end

    def mask_inline_styles(content)
      mask(mask(content, INLINE_STYLE_DOUBLE), INLINE_STYLE_SINGLE)
    end

    def mask_class_attributes(content)
      mask(mask(content, /\bclass\s*=\s*"[^"]*"/), /\bclass\s*=\s*'[^']*'/)
    end

    def mask_chars(string)
      newline_count = string.count("\n")
      "\n" * newline_count + " " * (string.length - newline_count)
    end

    def relative(file)
      file.relative_path_from(@root).to_s
    end

    def snippet(lines, idx)
      lines[idx]&.chomp&.strip
    end

    def apply_auto_fixes(violations)
      require_relative "audit/auto_fixer"
      fixer = AutoFixer.new(@root, output: @output, tokens: view_safe_tokens)
      applied = fixer.apply(violations)
      fixed_keys = applied.map { |r| [r.violation.file, r.violation.line, r.violation.column] }.to_set
      violations.reject { |v| fixed_keys.include?([v.file, v.line, v.column]) }
    end

    def write_suggestions(violations)
      require_relative "audit/markdown_writer"
      MarkdownWriter.new(@root, output: @output, tokens: view_safe_tokens).write(violations)
    end

    def view_safe_tokens
      # Views (HTML/ERB) cannot reference SCSS variables — `$primary` only
      # exists at SCSS compile time. CSS custom properties (`var(--primary)`)
      # work in any HTML/CSS context, so those are the only tokens that map
      # cleanly into a view violation's source.
      load_tokens.select { |t| t.syntax == :css_var }
    end

    def load_tokens
      require_relative "tokens"
      Tokens.new(root: @root, output: StringIO.new).parse_tokens
    rescue StandardError
      []
    end

    def print_report(violations)
      case @format
      when :json
        print_json(violations)
      else
        print_text(violations)
      end
    end

    def print_text(violations)
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

    def print_json(violations)
      require "json"
      payload = {
        summary: {
          total: violations.length,
          files: violations.map(&:file).uniq.length
        },
        violations: violations.map(&:to_h)
      }
      @output.puts JSON.pretty_generate(payload)
    end
  end
end
