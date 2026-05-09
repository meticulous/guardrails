# frozen_string_literal: true

require "pathname"

module Guardrails
  # Static a11y checks that don't require a browser — element-level rules
  # that can be answered from the source. For runtime a11y (color contrast,
  # focus order, ARIA tree, dynamic content) integrate axe-core-rspec
  # alongside Guardrails; see doc/A11Y.md.
  class A11yAudit
    Finding = Struct.new(:rule, :file, :line, :column, :snippet, keyword_init: true) do
      def to_h
        { rule: rule, file: file, line: line, column: column, snippet: snippet }
      end
    end

    SCAN_PATTERNS = [
      "app/views/**/*.html.erb",
      "app/components/**/*.html.erb"
    ].freeze

    ERB_BLOCK_PATTERN = /<%[\s\S]*?%>/
    HTML_COMMENT_PATTERN = /<!--[\s\S]*?-->/

    # Patterns that probe for the missing-attribute condition. Each tag
    # opening must already be on a single line for the line/column to be
    # meaningful.
    IMG_PATTERN = /<img\b([^>]*)>/i
    BUTTON_PATTERN = /<button\b([^>]*)>([\s\S]*?)<\/button>/i
    LINK_PATTERN = /<a\b([^>]*)>([\s\S]*?)<\/a>/i
    INPUT_PATTERN = /<input\b([^>]*)\/?>/i
    NON_INTERACTIVE_INPUT_TYPES = %w[hidden submit button reset image].freeze

    def initialize(root:, output: $stdout)
      @root = Pathname(root)
      @output = output
    end

    def run
      findings = view_files.flat_map { |path| scan_file(path) }
      print_report(findings)
      findings
    end

    private

    def view_files
      SCAN_PATTERNS
        .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
        .map { |path| Pathname(path) }
        .uniq
    end

    def scan_file(path)
      content = File.read(path, encoding: Encoding::UTF_8)
      # Mask HTML comments first so `<!-- <button></button> -->` doesn't
      # surface as a finding; then mask ERB so dynamic blocks don't either.
      comments_masked = content.gsub(HTML_COMMENT_PATTERN) { |m| mask_chars(m) }
      masked = comments_masked.gsub(ERB_BLOCK_PATTERN) { |m| mask_chars(m) }
      lines = content.lines

      findings = []
      findings.concat(scan_img(masked, path, lines))
      findings.concat(scan_button(masked, path, lines, content))
      findings.concat(scan_link(masked, path, lines, content))
      findings.concat(scan_input(masked, path, lines))
      findings
    end

    def scan_img(content, file, lines)
      results = []
      content.scan(IMG_PATTERN) do
        m = Regexp.last_match
        attrs = m[1]
        next if attribute_present?(attrs, "alt")

        results << finding(:image_alt, m, file, lines)
      end
      results
    end

    def scan_button(content, file, lines, original_content)
      results = []
      content.scan(BUTTON_PATTERN) do
        m = Regexp.last_match
        attrs = m[1]
        body = m[2]
        original_body = original_content[m.begin(2)...m.end(2)]
        next if button_has_accessible_name?(attrs, body, original_body)

        results << finding(:button_name, m, file, lines)
      end
      results
    end

    def scan_link(content, file, lines, original_content)
      results = []
      content.scan(LINK_PATTERN) do
        m = Regexp.last_match
        attrs = m[1]
        body = m[2]
        original_body = original_content[m.begin(2)...m.end(2)]
        next unless attribute_present?(attrs, "href")
        next if link_has_accessible_name?(attrs, body, original_body)

        results << finding(:link_name, m, file, lines)
      end
      results
    end

    def scan_input(content, file, lines)
      results = []
      content.scan(INPUT_PATTERN) do
        m = Regexp.last_match
        attrs = m[1]
        type = attribute_value(attrs, "type") || "text"
        next if NON_INTERACTIVE_INPUT_TYPES.include?(type.downcase)
        next if attribute_present?(attrs, "aria-label") || attribute_present?(attrs, "aria-labelledby")

        id = attribute_value(attrs, "id")
        next if id && content.include?(%(for="#{id}")) || (id && content.include?(%(for='#{id}')))

        results << finding(:input_label, m, file, lines)
      end
      results
    end

    def attribute_present?(attrs, name)
      attrs =~ /\b#{Regexp.escape(name)}\b/i
    end

    def attribute_value(attrs, name)
      m = attrs.match(/\b#{Regexp.escape(name)}\s*=\s*["']([^"']*)["']/i)
      m ? m[1] : nil
    end

    def button_has_accessible_name?(attrs, body, original_body)
      return true if attribute_present?(attrs, "aria-label") || attribute_present?(attrs, "aria-labelledby")
      # If the body wraps ERB output, defer to the helper_recommended
      # detector — that case isn't an a11y bug, it's a Rails-idiom hint.
      return true if has_erb_output?(original_body)

      visible_text(body).length.positive?
    end

    def link_has_accessible_name?(attrs, body, original_body)
      return true if attribute_present?(attrs, "aria-label") || attribute_present?(attrs, "aria-labelledby")
      return true if attribute_present?(attrs, "title")
      return true if has_erb_output?(original_body)

      visible_text(body).length.positive?
    end

    # Matches only ERB *output* tags (`<%= %>`). Control flow (`<% if %>`,
    # `<% end %>`) and comments (`<%# %>`) don't contribute renderable
    # content and shouldn't suppress the a11y rule.
    def has_erb_output?(body)
      body.match?(/<%=[\s\S]*?%>/)
    end

    def visible_text(body)
      body.gsub(/<[^>]+>/, "").strip
    end

    def finding(rule, match, file, lines)
      offset = match.begin(0)
      line_num = match.pre_match.count("\n") + 1
      column = offset - (match.pre_match.rindex("\n") || -1)
      Finding.new(
        rule: rule,
        file: file.relative_path_from(@root).to_s,
        line: line_num,
        column: column,
        snippet: lines[line_num - 1]&.chomp&.strip
      )
    end

    def mask_chars(string)
      newline_count = string.count("\n")
      "\n" * newline_count + " " * (string.length - newline_count)
    end

    def print_report(findings)
      return if findings.empty?

      @output.puts ""
      noun = findings.length == 1 ? "issue" : "issues"
      @output.puts "Guardrails a11y: #{findings.length} static #{noun} found"
      findings.each do |f|
        @output.puts "  [#{f.rule}] #{f.file}:#{f.line}:#{f.column}"
        @output.puts "    #{f.snippet}"
      end
    end
  end
end
