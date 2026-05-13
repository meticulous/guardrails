# frozen_string_literal: true

require "pathname"
require "set"
require_relative "erb_parser"
require_relative "report/style"

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

    NON_INTERACTIVE_INPUT_TYPES = %w[hidden submit button reset image].freeze

    SUGGESTION_FOR_RULE = {
      "image_alt" => "add an alt attribute (or alt=\"\" if decorative)",
      "button_name" => "add text, aria-label, or aria-labelledby",
      "link_name" => "add link text, aria-label, or aria-labelledby",
      "input_label" => "add aria-label, aria-labelledby, or a matching <label for=...>"
    }.freeze

    def initialize(root:, output: $stdout, style: nil)
      @root = Pathname(root)
      @output = output
      @style = style || Report::Style.new(io: output)
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
      lines = content.lines
      result = ErbParser.parse(content)
      @current_document = result.document
      @label_for_cache = nil

      findings = []
      ErbParser.each_node(result.document) do |node|
        case node
        when ::Herb::AST::HTMLElementNode then findings.concat(check_element(node, path, lines))
        when ::Herb::AST::HTMLOpenTagNode then findings.concat(check_void(node, path, lines)) if void_tag?(node)
        end
      end
      findings
    ensure
      @current_document = nil
      @label_for_cache = nil
    end

    def check_element(element, file, lines)
      tag = element_tag_name(element)
      case tag
      when "button" then check_button(element, file, lines)
      when "a" then check_link(element, file, lines)
      else []
      end
    end

    def check_void(open_tag, file, lines)
      tag = open_tag_name(open_tag)
      case tag
      when "img" then check_img(open_tag, file, lines)
      when "input" then check_input(open_tag, file, lines)
      else []
      end
    end

    def check_img(open_tag, file, lines)
      return [] if attribute_present?(open_tag, "alt")

      [build_finding(:image_alt, open_tag, file, lines)]
    end

    def check_button(element, file, lines)
      attrs_node = element.open_tag
      return [] if attribute_present?(attrs_node, "aria-label") || attribute_present?(attrs_node, "aria-labelledby")
      # Defer to helper_recommended for ERB-output bodies — the suggestion
      # there is more actionable than a generic missing-name flag.
      return [] if body_contains_erb_output?(element)
      return [] if visible_text_in(element).length.positive?

      [build_finding(:button_name, attrs_node, file, lines)]
    end

    def check_link(element, file, lines)
      attrs_node = element.open_tag
      return [] unless attribute_present?(attrs_node, "href")
      return [] if attribute_present?(attrs_node, "aria-label") || attribute_present?(attrs_node, "aria-labelledby")
      return [] if attribute_present?(attrs_node, "title")
      return [] if body_contains_erb_output?(element)
      return [] if visible_text_in(element).length.positive?

      [build_finding(:link_name, attrs_node, file, lines)]
    end

    def check_input(open_tag, file, lines)
      type = (attribute_static_value(open_tag, "type") || "text").downcase
      return [] if NON_INTERACTIVE_INPUT_TYPES.include?(type)
      return [] if attribute_present?(open_tag, "aria-label") || attribute_present?(open_tag, "aria-labelledby")

      id = attribute_static_value(open_tag, "id")
      return [] if id && labeled_by_for?(id)

      [build_finding(:input_label, open_tag, file, lines)]
    end

    def void_tag?(open_tag)
      %w[img input].include?(open_tag_name(open_tag))
    end

    def open_tag_name(open_tag)
      tok = open_tag.respond_to?(:tag_name) ? open_tag.tag_name : nil
      tok && tok.respond_to?(:value) ? tok.value.to_s.downcase : nil
    end

    def element_tag_name(element)
      open_tag_name(element.open_tag) if element.respond_to?(:open_tag) && element.open_tag
    end

    def attribute_nodes(open_tag)
      ErbParser.compact_children(open_tag).select { |c| c.is_a?(::Herb::AST::HTMLAttributeNode) }
    end

    def attribute_present?(open_tag, name)
      attribute_nodes(open_tag).any? { |attr| attribute_name(attr) == name.downcase }
    end

    def attribute_name(attr)
      name_wrapper, _ = ErbParser.compact_children(attr)
      return nil unless name_wrapper

      lit = ErbParser.compact_children(name_wrapper).first
      return nil unless lit && lit.respond_to?(:content)

      lit.content.respond_to?(:value) ? lit.content.value.to_s.downcase : lit.content.to_s.downcase
    end

    def attribute_static_value(open_tag, name)
      attr = attribute_nodes(open_tag).find { |a| attribute_name(a) == name.downcase }
      return nil unless attr

      _name_wrapper, value_wrapper = ErbParser.compact_children(attr)
      return nil unless value_wrapper

      ErbParser.compact_children(value_wrapper).filter_map do |child|
        next unless child.is_a?(::Herb::AST::LiteralNode)

        c = child.content
        c.respond_to?(:value) ? c.value.to_s : c.to_s
      end.join
    end

    # Walks the element's body subtree (including nested elements) for
    # `<%=` ERB output. Descendant-aware so that
    # `<button><span><%= label %></span></button>` is recognized as
    # wrapping ERB output and defers to helper_recommended — same
    # behavior the previous regex provided.
    def body_contains_erb_output?(element)
      body_nodes = Array(element.respond_to?(:body) ? element.body : [])
      body_nodes.any? { |child| descendant_has_erb_output?(child) }
    end

    def descendant_has_erb_output?(node)
      return false if node.nil?

      if node.is_a?(::Herb::AST::ERBContentNode)
        opening = node.tag_opening
        return (opening.respond_to?(:value) ? opening.value : opening.to_s) == "<%="
      end

      ErbParser.compact_children(node).any? { |child| descendant_has_erb_output?(child) }
    end

    # Concatenated visible text content from descendant HTMLTextNodes —
    # walks the entire subtree, including text inside nested elements
    # (`<button><span>Save</span></button>` returns "Save"). ERB nodes
    # don't contribute; the dynamic-content case is handled separately
    # by body_contains_erb_output?.
    def visible_text_in(element)
      text = +""
      ErbParser.each_node(element).each do |node|
        next unless node.is_a?(::Herb::AST::HTMLTextNode)

        c = node.content
        text << (c.respond_to?(:value) ? c.value.to_s : c.to_s)
      end
      text.strip
    end

    def labeled_by_for?(id)
      @label_for_cache ||= collect_labels_for_ids
      @label_for_cache.include?(id)
    end

    # Walk the AST once per file to collect every `<label>` element's
    # `for` attribute value into a Set. Cached for the duration of one
    # file's scan_file call so successive labeled_by_for? checks are O(1).
    def collect_labels_for_ids
      ids = Set.new
      ErbParser.each_node(@current_document) do |node|
        next unless node.is_a?(::Herb::AST::HTMLElementNode)
        next unless element_tag_name(node) == "label"

        v = attribute_static_value(node.open_tag, "for")
        ids << v if v
      end
      ids
    end

    def build_finding(rule, node, file, lines)
      line, column = ErbParser.start_position(node)
      Finding.new(
        rule: rule,
        file: file.relative_path_from(@root).to_s,
        line: line,
        column: column,
        snippet: lines[line - 1]&.chomp&.strip
      )
    end

    def print_report(findings)
      return if findings.empty?

      noun = findings.length == 1 ? "issue" : "issues"
      @output.puts ""
      @output.puts @style.section_heading(:error, "a11y (#{findings.length} static #{noun})")
      @output.puts "  Element-level a11y rules answerable from view source — missing alt text,"
      @output.puts "  unnamed buttons, unlabeled inputs, link without name. Full WCAG coverage"
      @output.puts "  needs runtime checks; layer axe-core via AXE_JSON= for that."

      findings.each do |f|
        @output.puts ""
        @output.puts "  #{@style.severity(:error, "#{f.rule}: #{f.snippet.to_s[0, 60]}")}"
        suggestion = SUGGESTION_FOR_RULE[f.rule.to_s]
        @output.puts "    #{@style.suggestion(suggestion)}" if suggestion
        @output.puts "    #{@style.location("#{f.file}:#{f.line}:#{f.column}")}"
      end
    end
  end
end
