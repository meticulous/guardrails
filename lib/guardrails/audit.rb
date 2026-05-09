# frozen_string_literal: true

require "pathname"
require "set"
require "stringio"
require "yaml"
require_relative "erb_parser"

module Guardrails
  class Audit
    Violation = Struct.new(:type, :file, :line, :column, :snippet, :value, keyword_init: true)

    DEFAULT_SCAN_PATHS = ["app/views", "app/components"].freeze
    SCAN_PATTERNS = DEFAULT_SCAN_PATHS.map { |p| "#{p}/**/*.html.erb" }.freeze

    # Subtrees that should never be scanned even if they happen to contain
    # ERB. These are merged with any user-supplied ignore paths from
    # guardrails.yml (in addition, not in place of). Vendor / node_modules
    # / tmp / public regularly contain third-party code that nobody wants
    # to "fix" through this lens.
    #
    # Note: `audit.ignore` entries are matched as exact paths or directory
    # prefixes (e.g. "app/views/layouts" excludes that subtree); they are
    # NOT interpreted as shell globs.
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
      # Tailwind_arbitrary still runs through the regex pipeline (HTML
      # comments and ERB blocks masked first to preserve line/column).
      # All other detectors are AST-based via Herb.
      masked = mask(content, HTML_COMMENT_PATTERN)
      masked_no_erb = mask(masked, ERB_BLOCK_PATTERN)

      ast_result = ErbParser.parse(content)

      detect_tailwind_arbitrary(masked_no_erb, file, original_lines) +
        detect_inline_styles_ast(ast_result, file, original_lines) +
        detect_raw_color_literals_ast(ast_result, file, original_lines) +
        detect_helper_recommended_ast(ast_result, file, original_lines)
    end

    # AST-based inline_style detector. Walks the parsed document for
    # HTMLElementNodes carrying a `style` attribute and emits one
    # violation per such attribute.
    def detect_inline_styles_ast(parse_result, file, original_lines)
      results = []
      ErbParser.each_node(parse_result.document) do |element|
        next unless element.is_a?(::Herb::AST::HTMLElementNode)

        attribute_nodes(element).each do |attr|
          next unless attribute_name(attr) == "style"

          line, column = ErbParser.start_position(attr)
          results << Violation.new(
            type: :inline_style,
            file: relative(file),
            line: line,
            column: column,
            snippet: snippet(original_lines, line - 1),
            value: inline_style_text_at(original_lines, line, column)
          )
        end
      end
      results
    end

    # AST-based raw_color detector. Scans color-bearing attribute values
    # for hex/rgb literals — but only the *static* portion of the value.
    # Mixed values like `fill="<%= shade %>"` produce no static text
    # against the literal pattern, so dynamic values don't false-flag.
    def detect_raw_color_literals_ast(parse_result, file, original_lines)
      results = []
      ErbParser.each_node(parse_result.document) do |element|
        next unless element.is_a?(::Herb::AST::HTMLElementNode)

        attribute_nodes(element).each do |attr|
          name = attribute_name(attr)
          next unless color_bearing_attribute?(name)

          static = static_attribute_value(attr)
          next if static.nil? || static.empty?

          [HEX_LITERAL_PATTERN, RGB_LITERAL_PATTERN].each do |pattern|
            static.scan(pattern) do |_|
              md = Regexp.last_match
              line, value_start_col = attribute_value_start(attr, original_lines)
              results << Violation.new(
                type: :raw_color,
                file: relative(file),
                line: line,
                column: value_start_col + md.begin(0),
                snippet: snippet(original_lines, line - 1),
                value: md[0]
              )
            end
          end
        end
      end
      results
    end

    COLOR_ATTRIBUTE_NAME_SET = COLOR_ATTRIBUTE_NAMES.map(&:downcase).to_set.freeze
    DATA_COLOR_ATTRIBUTE_PATTERN = /\Adata-[\w-]*colou?r[\w-]*\z/i

    def color_bearing_attribute?(name)
      return false if name.nil?

      COLOR_ATTRIBUTE_NAME_SET.include?(name) || name.match?(DATA_COLOR_ATTRIBUTE_PATTERN)
    end

    # Concatenate the literal portions of an attribute value. ERB-driven
    # parts are skipped — we can't statically know what they'll render.
    def static_attribute_value(attribute_node)
      _name_wrapper, value_wrapper = ErbParser.compact_children(attribute_node)
      return nil unless value_wrapper

      ErbParser.compact_children(value_wrapper).filter_map do |child|
        next unless child.is_a?(::Herb::AST::LiteralNode)

        literal_string(child)
      end.join
    end

    def literal_string(literal_node)
      content = literal_node.content
      content.respond_to?(:value) ? content.value.to_s : content.to_s
    end

    # Returns [line, column] for the first character of the attribute
    # *value* text — past any opening quote. Used so raw_color violations
    # report the column where the hex literal actually starts in source.
    def attribute_value_start(attribute_node, original_lines)
      _name_wrapper, value_wrapper = ErbParser.compact_children(attribute_node)
      return ErbParser.start_position(attribute_node) unless value_wrapper

      line, col = ErbParser.start_position(value_wrapper)
      line_text = original_lines[line - 1] || ""
      first_char = line_text[col - 1]
      col += 1 if first_char == '"' || first_char == "'"
      [line, col]
    end

    # Recover the on-disk `style="..."` snippet for the violation's
    # `value` field — Herb doesn't surface raw attribute source.
    def inline_style_text_at(original_lines, line, column)
      line_text = original_lines[line - 1] || ""
      tail = line_text[(column - 1)..] || ""
      match = tail.match(INLINE_STYLE_PATTERN)
      match ? match[0] : tail.split(/\s/, 2).first.to_s
    end

    # AST-based helper_recommended detector. Walks the parsed document
    # for HTMLElementNodes whose tag matches HELPER_RECOMMENDED_TAGS, and
    # flags ones that wrap an `<%=` ERB output (control flow `<% %>` and
    # `<%# %>` comments are excluded — they're distinguished by the
    # ERBContentNode#tag_opening value, not by guessing in regex).
    def detect_helper_recommended_ast(parse_result, file, original_lines)
      results = []
      ErbParser.each_node(parse_result.document) do |node|
        next unless node.is_a?(::Herb::AST::HTMLElementNode)

        tag = element_tag_name(node)
        next unless HELPER_RECOMMENDED_TAGS.key?(tag)
        next if tag == "a" && !element_has_attribute?(node, "href")
        next unless body_contains_erb_output?(node)

        line, column = ErbParser.start_position(node)
        results << Violation.new(
          type: :helper_recommended,
          file: relative(file),
          line: line,
          column: column,
          snippet: snippet(original_lines, line - 1),
          value: tag
        )
      end
      results
    end

    # HTMLElementNode#tag_name returns a Herb::Token; `.value` is the
    # raw string ("button", "a", etc).
    def element_tag_name(element)
      return nil unless element.respond_to?(:tag_name) && element.tag_name

      element.tag_name.respond_to?(:value) ? element.tag_name.value.to_s.downcase : nil
    end

    def element_has_attribute?(element, name)
      return false unless element.respond_to?(:open_tag) && element.open_tag

      attribute_nodes(element).any? { |attr| attribute_name(attr) == name.downcase }
    end

    def attribute_nodes(element)
      open_children = ErbParser.compact_children(element.open_tag)
      open_children.select { |child| child.is_a?(::Herb::AST::HTMLAttributeNode) }
    end

    # HTMLAttributeNode wraps a HTMLAttributeNameNode → LiteralNode chain.
    # The literal's `content` is the attribute name as a Herb::Token.
    def attribute_name(attribute_node)
      name_wrapper, _value_wrapper = ErbParser.compact_children(attribute_node)
      return nil unless name_wrapper

      literal = ErbParser.compact_children(name_wrapper).first
      return nil unless literal && literal.respond_to?(:content)

      literal.content.respond_to?(:value) ? literal.content.value.to_s.downcase : literal.content.to_s.downcase
    end

    def body_contains_erb_output?(element)
      body_nodes = element.respond_to?(:body) ? Array(element.body) : []
      body_nodes.any? do |child|
        next false unless child.is_a?(::Herb::AST::ERBContentNode)

        opening = child.tag_opening
        opening.respond_to?(:value) ? opening.value == "<%=" : opening.to_s == "<%="
      end
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
