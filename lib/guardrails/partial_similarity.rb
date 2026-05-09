# frozen_string_literal: true

require "pathname"
require "set"
require_relative "erb_parser"

module Guardrails
  class PartialSimilarity
    Finding = Struct.new(:file_a, :file_b, :score, :tag_count_a, :tag_count_b, keyword_init: true)

    DEFAULT_THRESHOLD = 0.7
    DEFAULT_NGRAM_SIZE = 3
    MIN_TAGS = 5

    # Scan ERB partials (underscore-prefixed in app/views and app/components)
    # AND ViewComponent sidecar templates (*_component.html.erb in app/components).
    PARTIAL_PATTERNS = [
      "app/views/**/_*.html.erb",
      "app/components/**/_*.html.erb",
      "app/components/**/*_component.html.erb"
    ].freeze

    def initialize(root:, output: $stdout, threshold: DEFAULT_THRESHOLD, ngram_size: DEFAULT_NGRAM_SIZE)
      @root = Pathname(root)
      @output = output
      @threshold = threshold
      @ngram_size = ngram_size
    end

    def run
      findings = compute_findings
      print_report(findings)
      findings
    end

    def compute_findings
      partials = collect_partials.filter_map do |path|
        tokens = tokenize(File.read(path, encoding: Encoding::UTF_8))
        next nil if tokens.length < MIN_TAGS

        { path: path, tokens: tokens, ngrams: build_ngrams(tokens) }
      end

      findings = []
      partials.combination(2).each do |a, b|
        score = jaccard(a[:ngrams], b[:ngrams])
        next if score < @threshold

        findings << Finding.new(
          file_a: a[:path].relative_path_from(@root).to_s,
          file_b: b[:path].relative_path_from(@root).to_s,
          score: score,
          tag_count_a: a[:tokens].length,
          tag_count_b: b[:tokens].length
        )
      end
      findings.sort_by { |f| -f.score }
    end

    # Tokenize a partial into a flat sequence of HTML tag names by walking
    # the parsed AST. Traversal is open-tag → recurse-into-body → close-tag
    # so the resulting sequence preserves source order:
    #
    #   <div><span></span></div>  →  ["div", "span", "span", "div"]
    #
    # ERB nodes don't contribute tokens. Void elements (img, input)
    # produce one token; their close-tag pass is skipped.
    def tokenize(content)
      tokens = []
      result = ErbParser.parse(content)
      walk_for_tokens(result.document, tokens)
      tokens
    end

    def walk_for_tokens(node, tokens)
      case node
      when ::Herb::AST::HTMLElementNode
        name = element_tag_name(node)
        if name
          tokens << name
          Array(node.body).each { |child| walk_for_tokens(child, tokens) }
          tokens << name unless void_element_name?(name)
        end
      when ::Herb::AST::HTMLOpenTagNode
        # Top-level void element not wrapped in HTMLElementNode.
        name = open_tag_name(node)
        tokens << name if name && void_element_name?(name)
      else
        ErbParser.compact_children(node).each { |child| walk_for_tokens(child, tokens) }
      end
    end

    VOID_ELEMENT_NAMES = %w[
      area base br col embed hr img input link meta param source track wbr
    ].to_set.freeze

    def void_element_name?(name)
      VOID_ELEMENT_NAMES.include?(name)
    end

    def open_tag_name(node)
      tok = node.respond_to?(:tag_name) ? node.tag_name : nil
      tok && tok.respond_to?(:value) ? tok.value.to_s.downcase : nil
    end

    def element_tag_name(element)
      open_tag_name(element.open_tag) if element.respond_to?(:open_tag) && element.open_tag
    end

    private

    def collect_partials
      PARTIAL_PATTERNS
        .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
        .map { |path| Pathname(path) }
        .uniq
        .sort
    end

    def build_ngrams(tokens)
      return Set.new([tokens]) if tokens.length < @ngram_size

      tokens.each_cons(@ngram_size).to_set
    end

    def jaccard(set_a, set_b)
      return 0.0 if set_a.empty? && set_b.empty?

      intersection = (set_a & set_b).size.to_f
      union = (set_a | set_b).size
      intersection / union
    end

    def print_report(findings)
      return if findings.empty?

      @output.puts ""
      noun = findings.length == 1 ? "pair" : "pairs"
      @output.puts "Guardrails templates: #{findings.length} similar #{noun} (>= #{@threshold} structural similarity)"
      findings.each do |f|
        @output.puts "  #{format('%.2f', f.score)}  #{f.file_a} ↔ #{f.file_b}  (#{f.tag_count_a} / #{f.tag_count_b} tags)"
      end
    end
  end
end
