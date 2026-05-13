# frozen_string_literal: true

require "pathname"
require "set"
require "stringio"
require "yaml"
require_relative "erb_parser"
require_relative "report/style"

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

    # Path-component patterns that are also implicit-ignored. Mailer
    # views are auto-skipped because email clients require inline
    # styles — flagging them as design-system drift is incorrect by
    # design.
    #
    # Matches both Rails conventions:
    #   app/views/contact_mailer/    (*_mailer convention from Talos)
    #   app/views/devise/mailer/     (plain `mailer` from Forem/Devise)
    #
    # The leading-underscore prefix is required for the prefix path so
    # `_mailer_partial/` (a regular partials dir) doesn't match.
    IMPLICIT_IGNORE_PATTERNS = [
      /\A(?:\w+_)?mailer\z/
    ].freeze

    # Color literal patterns — applied to the static portion of an
    # attribute value extracted via the AST.
    HEX_LITERAL_PATTERN = /#[0-9a-fA-F]{3,8}\b/
    RGB_LITERAL_PATTERN = /\brgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+(?:\s*,\s*[\d.]+)?\s*\)/

    # Tailwind arbitrary-value bracket pattern — applied to the static
    # portion of a class attribute value.
    ARBITRARY_VALUE_PATTERN = /\[[^\]]+\]/

    # Pattern used only to recover the on-disk `style="..."` snippet for
    # the inline_style violation's `value` field. Detection itself is
    # AST-based; this is just for nicer reporting.
    INLINE_STYLE_PATTERN = /\bstyle\s*=\s*["'][^"']+["']/

    # Elements where wrapping ERB output in literal HTML hides intent
    # from static analysis. Mapped to the Rails helper that does the
    # same job with attributes (including aria-*) centralized.
    HELPER_RECOMMENDED_TAGS = {
      "button" => "tag.button(label, ...) or button_to(label, path) for forms",
      "a" => "link_to(label, path, ...)"
    }.freeze

    # Attributes whose values legitimately carry color literals. Scoping
    # raw_color detection to these keeps href="#section" or data-id="abc"
    # from being misreported as color drift.
    COLOR_ATTRIBUTE_NAMES = %w[
      fill stroke color bgcolor background
      flood-color lighting-color stop-color
    ].freeze

    def initialize(root:, output: $stdout, suggest: false, format: :text, apply: false, style: nil)
      @root = Pathname(root)
      @output = output
      @suggest = suggest
      @format = format
      @apply = apply
      @config = load_audit_config
      @style = style
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
      return true if segments.any? { |seg| IMPLICIT_IGNORE_PATTERNS.any? { |pat| seg.match?(pat) } }

      Array(@config["ignore"] || []).any? do |ignore|
        relative == ignore || relative.start_with?("#{ignore}/")
      end
    end

    def scan_file(file)
      content = File.read(file, encoding: Encoding::UTF_8)
      original_lines = content.lines
      ast_result = ErbParser.parse(content)

      detect_inline_styles_ast(ast_result, file, original_lines) +
        detect_raw_color_literals_ast(ast_result, file, original_lines) +
        detect_tailwind_arbitrary_ast(ast_result, file, original_lines) +
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
    # ERBContentNode#tag_opening value).
    #
    # Skips elements that already declare aria-label or aria-labelledby:
    # the user has explicitly handled accessibility on the literal tag,
    # so the suggestion to switch to `tag.button` / `link_to` is just
    # idiom noise, not a real signal. Found in dogfooding against Talos
    # (16 of 44 findings were on aria-labeled icon buttons).
    def detect_helper_recommended_ast(parse_result, file, original_lines)
      results = []
      ErbParser.each_node(parse_result.document) do |node|
        next unless node.is_a?(::Herb::AST::HTMLElementNode)

        tag = element_tag_name(node)
        next unless HELPER_RECOMMENDED_TAGS.key?(tag)
        next if tag == "a" && !element_has_attribute?(node, "href")
        next if element_has_attribute?(node, "aria-label") || element_has_attribute?(node, "aria-labelledby")
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

    # Walks the element's body subtree (including nested elements)
    # looking for any `<%=` ERB output. The previous regex scanned the
    # whole body string, so deeply-nested cases like
    # `<button><span><%= label %></span></button>` registered too —
    # preserving that behavior matters because the helper-recommendation
    # is exactly as relevant when the dynamic content is one level down.
    def body_contains_erb_output?(element)
      body_nodes = element.respond_to?(:body) ? Array(element.body) : []
      body_nodes.any? { |child| descendant_has_erb_output?(child) }
    end

    def descendant_has_erb_output?(node)
      return false if node.nil?

      if node.is_a?(::Herb::AST::ERBContentNode)
        opening = node.tag_opening
        return opening.respond_to?(:value) ? opening.value == "<%=" : opening.to_s == "<%="
      end

      ErbParser.compact_children(node).any? { |child| descendant_has_erb_output?(child) }
    end

    # AST-based tailwind_arbitrary detector. Walks element class
    # attributes and flags any `[...]` arbitrary value found in the
    # static portion of the class string. ERB-driven class fragments
    # don't contribute static text, so dynamic class names don't
    # false-flag.
    def detect_tailwind_arbitrary_ast(parse_result, file, original_lines)
      results = []
      ErbParser.each_node(parse_result.document) do |element|
        next unless element.is_a?(::Herb::AST::HTMLElementNode)

        attribute_nodes(element).each do |attr|
          next unless attribute_name(attr) == "class"

          static = static_attribute_value(attr)
          next if static.nil? || static.empty?

          static.scan(ARBITRARY_VALUE_PATTERN) do |_|
            md = Regexp.last_match
            inner_value = md[0][1..-2] # strip [ and ]
            line, value_start_col = attribute_value_start(attr, original_lines)
            results << Violation.new(
              type: :tailwind_arbitrary,
              file: relative(file),
              line: line,
              column: value_start_col + md.begin(0),
              snippet: snippet(original_lines, line - 1),
              value: inner_value
            )
          end
        end
      end
      results
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
        @output.puts ""
        @output.puts "#{style.colorize("✓", :green)} Guardrails audit: no violations found."
        return
      end

      # Group by type so each rule gets its own section with framing
      # intro + tagged findings + inline suggestion arrows. The order
      # mirrors what users care about: hex literals + inline styles +
      # arbitrary Tailwind (real violations) before helper_recommended
      # (a suggestion-shaped warning) and a11y (errors but grouped
      # separately because A11yAudit owns them — the audit rake task
      # threads them in via this same method).
      type_order = %i[inline_style raw_color tailwind_arbitrary helper_recommended
                      image_alt button_name link_name input_label]
      by_type = violations.group_by(&:type)
      ordered = type_order + (by_type.keys - type_order)

      ordered.each do |type|
        list = by_type[type] || []
        next if list.empty?

        print_violation_type(type, list)
      end
    end

    SEVERITY_FOR_TYPE = {
      inline_style: :warning,
      raw_color: :error,
      tailwind_arbitrary: :error,
      helper_recommended: :warning,
      image_alt: :error,
      button_name: :error,
      link_name: :error,
      input_label: :error
    }.freeze

    FRAMING_FOR_TYPE = {
      inline_style: "Inline style attributes bypass your design tokens. Extract these to a CSS class or component stylesheet that references defined tokens.",
      raw_color: "Hex/rgb literals in color attributes bypass your design tokens. Run APPLY=1 to auto-fix where a token matches; SUGGEST=1 writes a markdown checklist.",
      tailwind_arbitrary: "Arbitrary Tailwind values (bg-[#fa3] etc.) bypass your theme. Add the value to theme.colors / theme.fontSize and use the named utility, or APPLY=1 to auto-fix where a token matches.",
      helper_recommended: "Literal <button>/<a> wrapping ERB output hides intent from static analysis and a11y tooling. Switch to tag.button / link_to / button_to so attributes flow through one place.",
      image_alt: "Images need accessible alt text. Use alt=\"\" for purely decorative images.",
      button_name: "Buttons need an accessible name — text content, aria-label, or aria-labelledby.",
      link_name: "Links need an accessible name — text content, aria-label, or aria-labelledby.",
      input_label: "Interactive inputs need a programmatic label — aria-label, aria-labelledby, or a matching <label for=...>."
    }.freeze

    AUTO_FIXABLE_TYPES = %i[raw_color tailwind_arbitrary].freeze

    def print_violation_type(type, violations)
      severity = SEVERITY_FOR_TYPE.fetch(type, :warning)
      auto_fix_marker = AUTO_FIXABLE_TYPES.include?(type) ? ", auto-fix available" : ""

      @output.puts ""
      @output.puts style.section_heading(
        severity,
        "#{type} (#{violations.length} #{violations.length == 1 ? "finding" : "findings"}#{auto_fix_marker})"
      )
      framing = FRAMING_FOR_TYPE[type]
      wrap_framing(framing).each { |line| @output.puts "  #{line}" } if framing

      violations.each do |v|
        @output.puts ""
        header = "#{type}: #{format_value(v)}"
        @output.puts "  #{style.severity(severity, header)}"
        suggestion = suggestion_for_violation(v)
        @output.puts "    #{style.suggestion(suggestion)}" if suggestion
        @output.puts "    #{style.location("#{v.file}:#{v.line}:#{v.column}")}"
        @output.puts "    #{v.snippet}" if v.snippet
      end
    end

    def format_value(violation)
      case violation.type
      when :raw_color, :tailwind_arbitrary
        violation.value
      when :inline_style
        violation.value || "<inline style>"
      else
        violation.snippet.to_s[0, 60]
      end
    end

    # Hard-wrap the framing-intro paragraph at ~72 chars so it doesn't
    # run off the side of an 80-col terminal. Cheap word-wrap; nothing
    # fancy needed for a 1-2 sentence paragraph.
    def wrap_framing(text, width: 72)
      lines = []
      current = +""
      text.split(/\s+/).each do |word|
        if current.empty?
          current << word
        elsif current.length + 1 + word.length <= width
          current << " " << word
        else
          lines << current
          current = +word
        end
      end
      lines << current unless current.empty?
      lines
    end

    # Per-violation inline suggestion. For token-aware types
    # (raw_color, tailwind_arbitrary), reuse load_tokens + TokenMatcher
    # to surface exact matches inline. Anything more elaborate
    # (near-match, replacement string, etc.) belongs in SUGGEST=1's
    # markdown checklist.
    def suggestion_for_violation(violation)
      case violation.type
      when :raw_color
        matched_token_suggestion(violation, [:css_var])
      when :tailwind_arbitrary
        matched_token_suggestion(violation, [:tailwind]) ||
          matched_token_suggestion(violation, [:css_var])
      when :inline_style
        "extract to a CSS class or component stylesheet"
      when :helper_recommended
        helper_recommended_suggestion(violation)
      when :image_alt
        "add an alt attribute (or alt=\"\" if decorative)"
      when :button_name
        "add text, aria-label, or aria-labelledby"
      when :link_name
        "add link text, aria-label, or aria-labelledby"
      when :input_label
        "add aria-label, aria-labelledby, or a matching <label for=...>"
      end
    end

    def matched_token_suggestion(violation, allowed_syntaxes)
      require_relative "token_matcher"
      tokens = load_tokens.select { |t| allowed_syntaxes.include?(t.syntax) }
      return nil if tokens.empty?

      match = TokenMatcher.new(tokens).match(violation.value)
      return nil unless match && match.kind == :exact

      token = match.token
      "replace with #{token_reference(token)} (exact match from #{token.file})"
    end

    def token_reference(token)
      case token.syntax
      when :css_var then "var(--#{token.name})"
      when :scss_var then "$#{token.name}"
      when :tailwind then token.name.to_s
      else token.name.to_s
      end
    end

    def helper_recommended_suggestion(violation)
      tag = violation.snippet.to_s[/<(\w+)/, 1]
      case tag
      when "button" then "use tag.button(label, ...) or button_to(label, path)"
      when "a" then "use link_to(label, path, ...)"
      else "use the Rails helper for this element"
      end
    end

    def style
      @style ||= Report::Style.new(io: @output)
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
