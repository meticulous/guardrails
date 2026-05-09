# frozen_string_literal: true

require "pathname"
require "set"
require "stringio"
require "yaml"

module Guardrails
  class Audit
    Violation = Struct.new(:type, :file, :line, :column, :snippet, :value, keyword_init: true)

    DEFAULT_SCAN_PATHS = ["app/views", "app/components"].freeze
    SCAN_PATTERNS = DEFAULT_SCAN_PATHS.map { |p| "#{p}/**/*.html.erb" }.freeze

    # Subtrees that should never be scanned even if they happen to contain
    # ERB. These are merged with any user-supplied ignore globs from
    # guardrails.yml (in addition, not in place of). Vendor / node_modules
    # / tmp / public regularly contain third-party code that nobody wants
    # to "fix" through this lens.
    IMPLICIT_IGNORE = %w[vendor node_modules tmp public log].freeze

    INLINE_STYLE_PATTERN = /\bstyle\s*=\s*["'][^"']+["']/
    ERB_BLOCK_PATTERN = /<%[\s\S]*?%>/
    HTML_COMMENT_PATTERN = /<!--[\s\S]*?-->/
    HEX_LITERAL_PATTERN = /#[0-9a-fA-F]{3,8}\b/
    RGB_LITERAL_PATTERN = /\brgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+(?:\s*,\s*[\d.]+)?\s*\)/
    CLASS_ATTRIBUTE_DOUBLE = /\bclass\s*=\s*"([^"]*)"/
    CLASS_ATTRIBUTE_SINGLE = /\bclass\s*=\s*'([^']*)'/
    ARBITRARY_VALUE_PATTERN = /\[[^\]]+\]/

    # Elements where wrapping ERB output in literal HTML obscures static
    # analysis (the body looks empty after ERB masking). Mapped to the
    # Rails helper that handles the same case more cleanly.
    HELPER_RECOMMENDED_TAGS = {
      "button" => "tag.button(label, ...) or button_to(label, path) for forms",
      "a" => "link_to(label, path, ...)"
    }.freeze
    # Match only ERB *output* tags (`<%= %>`), not control flow (`<% if %>`)
    # or comments (`<%# %>`). The helper-recommendation rule is about
    # rendering dynamic text inside a literal element, not about any ERB
    # presence in the body.
    ERB_OUTPUT_PATTERN = /<%=[\s\S]*?%>/

    # Attributes whose values legitimately carry color literals. Scoping
    # raw_color detection to these keeps href="#section" or data-id="abc"
    # from being misreported as color drift.
    COLOR_ATTRIBUTE_NAMES = %w[
      fill stroke color bgcolor background
      flood-color lighting-color stop-color
    ].freeze
    COLOR_ATTRIBUTE_PATTERN = Regexp.union(
      [
        /\b(?:#{COLOR_ATTRIBUTE_NAMES.join('|')})\s*=\s*"([^"]*)"/i,
        /\b(?:#{COLOR_ATTRIBUTE_NAMES.join('|')})\s*=\s*'([^']*)'/i,
        /\bdata-[\w-]*colou?r[\w-]*\s*=\s*"([^"]*)"/i,
        /\bdata-[\w-]*colou?r[\w-]*\s*=\s*'([^']*)'/i
      ]
    )

    def initialize(root:, output: $stdout, suggest: false, format: :text, apply: false)
      @root = Pathname(root)
      @output = output
      @suggest = suggest
      @format = format
      @apply = apply
      @config = load_audit_config
    end

    def run
      violations = collect_files.flat_map { |file| scan_file(file) }
      print_report(violations)
      remaining = @apply ? apply_auto_fixes(violations) : violations
      write_suggestions(remaining) if @suggest
      remaining
    end

    private

    def load_audit_config
      config_path = @root.join("guardrails.yml")
      return {} unless config_path.exist?

      (YAML.safe_load_file(config_path) || {}).dig("guardrails", "audit") || {}
    rescue StandardError
      {}
    end

    def scan_paths
      paths = @config["scan_paths"] || DEFAULT_SCAN_PATHS
      Array(paths)
    end

    def ignore_paths
      # Returned for the audit config knob; the actual filter logic lives
      # in `ignored?` because implicit and user ignores match differently.
      IMPLICIT_IGNORE + Array(@config["ignore"] || [])
    end

    def collect_files
      patterns = scan_paths.map { |p| File.join(p, "**/*.html.erb") }
      patterns
        .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
        .map { |path| Pathname(path) }
        .uniq
        .reject { |path| ignored?(path) }
    end

    def ignored?(path)
      relative = path.relative_path_from(@root).to_s
      segments = relative.split("/")

      # Implicit ignores match on any path component — `vendor` blocks
      # both top-level `vendor/foo` and nested `app/assets/stylesheets/
      # vendor/foo`. User-configured ignores keep the original prefix
      # semantics so they can name specific subtrees.
      return true if (IMPLICIT_IGNORE & segments).any?

      Array(@config["ignore"] || []).any? do |ignore|
        relative == ignore || relative.start_with?("#{ignore}/")
      end
    end

    def scan_file(file)
      content = File.read(file, encoding: Encoding::UTF_8)
      original_lines = content.lines
      # Mask HTML comments first so commented-out markup doesn't trip
      # detectors. Then mask ERB blocks. Both masks preserve line and
      # column positions.
      masked = mask(content, HTML_COMMENT_PATTERN)
      masked_no_erb = mask(masked, ERB_BLOCK_PATTERN)

      detect_inline_styles(masked_no_erb, file, original_lines) +
        detect_raw_color_literals(masked_no_erb, file, original_lines) +
        detect_tailwind_arbitrary(masked_no_erb, file, original_lines) +
        detect_helper_recommended(masked, file, original_lines)
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
      violations = []
      content.each_line.with_index do |line, idx|
        line.scan(COLOR_ATTRIBUTE_PATTERN) do
          outer = Regexp.last_match
          attr_value = outer.captures.compact.first
          next if attr_value.nil? || attr_value.empty?

          # The captured group's start position may be in any of the union's
          # alternatives — find whichever one matched.
          value_start = (1..outer.captures.length).map { |i| outer.begin(i) }.compact.first

          [HEX_LITERAL_PATTERN, RGB_LITERAL_PATTERN].each do |pattern|
            attr_value.scan(pattern) do
              inner = Regexp.last_match
              violations << Violation.new(
                type: :raw_color,
                file: relative(file),
                line: idx + 1,
                column: value_start + inner.begin(0) + 1,
                snippet: snippet(original_lines, idx),
                value: inner[0]
              )
            end
          end
        end
      end
      violations
    end

    def detect_helper_recommended(content, file, original_lines)
      results = []
      HELPER_RECOMMENDED_TAGS.each_key do |tag|
        pattern = /<#{tag}\b([^>]*)>([\s\S]*?)<\/#{tag}>/m
        content.scan(pattern) do
          m = Regexp.last_match
          attrs = m[1]
          body = m[2]
          next unless body.match?(ERB_OUTPUT_PATTERN)
          # Suggesting link_to for an <a> without href would be wrong —
          # named anchors and JS-only hooks aren't navigation.
          next if tag == "a" && !attrs.match?(/\bhref\b/i)

          offset = m.begin(0)
          line_num = m.pre_match.count("\n") + 1
          col_base = m.pre_match.rindex("\n")
          column = col_base ? offset - col_base : offset + 1
          results << Violation.new(
            type: :helper_recommended,
            file: relative(file),
            line: line_num,
            column: column,
            snippet: snippet(original_lines, line_num - 1),
            value: tag
          )
        end
      end
      results
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

    # Replace every non-newline character with a space, leaving newlines
    # in their original positions. The earlier "newlines first, spaces
    # after" implementation kept the total length right but shifted line
    # breaks, which made line/column reports for content AFTER a
    # multi-line masked region land on the wrong line.
    def mask_chars(string)
      string.gsub(/[^\n]/, " ")
    end

    def relative(file)
      file.relative_path_from(@root).to_s
    end

    def snippet(lines, idx)
      lines[idx]&.chomp&.strip
    end

    def apply_auto_fixes(violations)
      require_relative "audit/auto_fixer"
      fixer = AutoFixer.new(
        @root,
        output: @output,
        tokens: load_tokens,
        near_match_policy: near_match_policy,
        near_match_threshold: near_match_threshold
      )
      applied = fixer.apply(violations)
      fixed_keys = applied.map { |r| [r.violation.file, r.violation.line, r.violation.column] }.to_set
      violations.reject { |v| fixed_keys.include?([v.file, v.line, v.column]) }
    end

    def write_suggestions(violations)
      require_relative "audit/markdown_writer"
      MarkdownWriter.new(
        @root,
        output: @output,
        tokens: load_tokens,
        near_match_policy: near_match_policy,
        near_match_threshold: near_match_threshold
      ).write(violations)
    end

    def near_match_policy
      tokens_config["near_match_policy"] || "notify"
    end

    def near_match_threshold
      raw = tokens_config["near_match_threshold"]
      raw.is_a?(Numeric) ? raw : 4
    end

    def tokens_config
      config_path = @root.join("guardrails.yml")
      return {} unless config_path.exist?

      config = YAML.safe_load_file(config_path) || {}
      config.dig("guardrails", "tokens") || {}
    rescue StandardError
      {}
    end

    # Returns the full token list across colors_file, type_scale_file, and
    # tailwind.config.js. MarkdownWriter and AutoFixer filter by token
    # syntax against the current violation type — `$primary` doesn't
    # compile in HTML attrs and `bg-primary` only makes sense for
    # tailwind_arbitrary contexts, so the dispatch happens at use.
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
