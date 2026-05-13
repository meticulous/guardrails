# frozen_string_literal: true

require "pathname"
require "set"
require_relative "erb_parser"
require_relative "report/style"

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

    def initialize(root:, output: $stdout, threshold: DEFAULT_THRESHOLD,
                   ngram_size: DEFAULT_NGRAM_SIZE, style: nil)
      @root = Pathname(root)
      @output = output
      @threshold = threshold
      @ngram_size = ngram_size
      @style = style || Report::Style.new(io: output)
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

    # Group findings by connected component over the similarity graph.
    # When N partials are pairwise above-threshold (e.g. 8 templated
    # public_activity partials all matching each other at 1.00), the
    # naive pair list emits C(N,2) lines that read as noise; collapsing
    # to one group of N is what the user actually cares about.
    #
    # Returns an Array of Hashes keyed by:
    #   :files       — sorted Array of file paths in the component
    #   :score_min, :score_max — observed score range across the
    #                            component's pairs
    #   :pair_count  — how many original pairs fed into the group
    #   :sample_pair — a representative Finding (the only one for size-2
    #                  components, used to preserve the original pair
    #                  line's tag-count detail)
    def group_findings(findings)
      adj = Hash.new { |h, k| h[k] = Set.new }
      pairs_by_file = Hash.new { |h, k| h[k] = [] }
      findings.each do |f|
        adj[f.file_a] << f.file_b
        adj[f.file_b] << f.file_a
        pairs_by_file[f.file_a] << f
        pairs_by_file[f.file_b] << f
      end

      visited = Set.new
      groups = []
      adj.each_key do |file|
        next if visited.include?(file)

        component = Set.new
        stack = [file]
        until stack.empty?
          current = stack.pop
          next if component.include?(current)

          component << current
          visited << current
          adj[current].each { |neighbor| stack << neighbor unless component.include?(neighbor) }
        end

        # Walk only the findings touching files in this component (via the
        # pre-built index) — avoids the O(components × pairs) scan.
        seen_pair_ids = Set.new
        component_pairs = []
        component.each do |f|
          pairs_by_file[f].each do |pair|
            next unless component.include?(pair.file_a) && component.include?(pair.file_b)
            next if seen_pair_ids.include?(pair.object_id)

            seen_pair_ids << pair.object_id
            component_pairs << pair
          end
        end

        scores = component_pairs.map(&:score)
        groups << {
          files: component.to_a.sort,
          score_min: scores.min,
          score_max: scores.max,
          pair_count: component_pairs.size,
          sample_pair: component_pairs.first
        }
      end
      groups.sort_by { |g| -g[:files].size }
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

      groups = group_findings(findings)
      total_files = groups.sum { |g| g[:files].size }
      group_noun = groups.length == 1 ? "group" : "groups"

      @output.puts ""
      @output.puts @style.section_heading(
        :suggestion,
        "similar partials (#{groups.length} #{group_noun}, #{findings.length} pairs, #{total_files} files)"
      )
      @output.puts "  Templates with >= #{@threshold} structural similarity. Likely duplicates;"
      @output.puts "  consider extracting the common shape into a partial or parameterizing"
      @output.puts "  one with locals to subsume the others."

      groups.each do |group|
        @output.puts ""
        if group[:files].length == 2
          # Pair — keep the tag-count suffix; it's a useful signal of
          # how big the templates are.
          pair = group[:sample_pair]
          file_a, file_b = group[:files]
          header = "#{format('%.2f', group[:score_max])} similar: #{file_a} ↔ #{file_b}"
          @output.puts "  #{@style.severity(:suggestion, header)}"
          @output.puts "    #{@style.suggestion(suggestion_for_pair(group))}"
          @output.puts "    #{@style.location("#{pair.tag_count_a} / #{pair.tag_count_b} tags")}"
        else
          score_label = if group[:score_min] == group[:score_max]
                         format("%.2f", group[:score_max])
                       else
                         "#{format('%.2f', group[:score_min])}–#{format('%.2f', group[:score_max])}"
                       end
          header = "group of #{group[:files].length} similar templates (#{score_label}, #{group[:pair_count]} pairs)"
          @output.puts "  #{@style.severity(:suggestion, header)}"
          @output.puts "    #{@style.suggestion(suggestion_for_group(group))}"
          group[:files].each { |f| @output.puts "    #{@style.location(f)}" }
        end
      end
    end

    def suggestion_for_pair(group)
      score = group[:score_max]
      if score >= 0.95
        "near-identical — pick one and delete the other, or merge with locals"
      elsif score >= 0.85
        "very similar — parameterize one with locals and render it from the other"
      else
        "shared structure — consider a partial that both can render"
      end
    end

    def suggestion_for_group(group)
      "#{group[:files].length} templates sharing structure — strong candidate for one shared partial"
    end
  end
end
