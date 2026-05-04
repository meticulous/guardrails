# frozen_string_literal: true

require "pathname"
require "set"

module Guardrails
  class PartialSimilarity
    Finding = Struct.new(:file_a, :file_b, :score, :tag_count_a, :tag_count_b, keyword_init: true)

    DEFAULT_THRESHOLD = 0.7
    DEFAULT_NGRAM_SIZE = 3
    MIN_TAGS = 5

    PARTIAL_PATTERNS = [
      "app/views/**/_*.html.erb",
      "app/components/**/_*.html.erb"
    ].freeze

    HTML_TAG_PATTERN = /<\/?\s*([a-zA-Z][\w-]*)\b[^>]*>/
    ERB_BLOCK_PATTERN = /<%[\s\S]*?%>/

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

    def tokenize(content)
      masked = content.gsub(ERB_BLOCK_PATTERN, "")
      masked.scan(HTML_TAG_PATTERN).flatten.map(&:downcase)
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
      @output.puts "Guardrails partials: #{findings.length} similar #{noun} (>= #{@threshold} structural similarity)"
      findings.each do |f|
        @output.puts "  #{format('%.2f', f.score)}  #{f.file_a} ↔ #{f.file_b}  (#{f.tag_count_a} / #{f.tag_count_b} tags)"
      end
    end
  end
end
