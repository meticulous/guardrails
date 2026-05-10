# frozen_string_literal: true

require "pathname"
require "digest"
require "set"
require_relative "erb_parser"

module Guardrails
  # Finds recurring structural patterns across the codebase — element
  # subtrees that appear in 3+ places and could be extracted into a
  # shared partial or ViewComponent.
  #
  # Distinct from PartialSimilarity: that one compares EXISTING partials
  # against each other ("are these two partials near-duplicates?").
  # CrossCodebasePatterns looks at the structural shape of any subtree
  # in any view ("this 8-element shape appears in 12 places, only one
  # of which is a partial — refactor candidate").
  class CrossCodebasePatterns
    Occurrence = Struct.new(:file, :line, :column, :size, keyword_init: true)

    Pattern = Struct.new(:fingerprint, :shape, :size, :occurrences, keyword_init: true) do
      def count
        occurrences.length
      end
    end

    # Minimum number of element nodes in a subtree before we consider it.
    # Below this, the structural shape is too generic to be a refactor
    # candidate — `<div>` alone, or `<span><a></a></span>`, would match
    # constantly. A useful pattern starts around 5 elements (card body,
    # form row, table cell with controls, etc.).
    DEFAULT_MIN_SIZE = 5

    # Subtree fingerprint must appear at least this many times to surface.
    # 2 occurrences are common and rarely actionable; 3+ implies a real
    # repeated shape.
    DEFAULT_MIN_OCCURRENCES = 3

    # Max occurrences printed per pattern before we elide the rest.
    DEFAULT_MAX_OCCURRENCES_SHOWN = 10

    VIEW_PATTERNS = [
      "app/views/**/*.html.erb",
      "app/components/**/*.html.erb"
    ].freeze

    IMPLICIT_IGNORE_SEGMENTS = %w[vendor node_modules tmp public log].freeze
    IMPLICIT_IGNORE_PATTERNS = [/\A(?:\w+_)?mailer\z/].freeze

    def initialize(root:, output: $stdout,
                   min_size: DEFAULT_MIN_SIZE,
                   min_occurrences: DEFAULT_MIN_OCCURRENCES,
                   max_occurrences_shown: DEFAULT_MAX_OCCURRENCES_SHOWN)
      @root = Pathname(root)
      @output = output
      @min_size = min_size
      @min_occurrences = min_occurrences
      @max_occurrences_shown = max_occurrences_shown
    end

    def run
      patterns = find_patterns
      print_report(patterns)
      patterns
    end

    def find_patterns
      occurrences = Hash.new { |h, k| h[k] = [] }
      shapes = {}

      view_files.each do |file|
        content = File.read(file, encoding: Encoding::UTF_8)
        result = ErbParser.parse(content)
        relative = file.relative_path_from(@root).to_s

        walk_subtrees(result.document) do |node, fingerprint, shape, size|
          next if size < @min_size

          loc_start = node.location.start
          occurrences[fingerprint] << Occurrence.new(
            file: relative,
            line: loc_start.line,
            column: loc_start.column + 1,
            size: size
          )
          shapes[fingerprint] ||= shape
        end
      end

      patterns = occurrences
                 .select { |_, occs| occs.size >= @min_occurrences }
                 .map { |fp, occs| Pattern.new(fingerprint: fp, shape: shapes[fp], size: occs.first.size, occurrences: occs) }
                 .sort_by { |p| [-p.count, -p.size] }

      dedupe_nested(patterns)
    end

    private

    # Drop redundant inner shapes. When a table repeats N times, three
    # patterns end up with identical counts:
    #
    #   table(thead(tr(th,th,th)),tbody)   8x
    #   thead(tr(th,th,th))                 8x
    #   tr(th,th,th)                        8x
    #
    # The outer pattern is the one a refactor would extract; the inner
    # shapes are just nested views of the same locations. Drop pattern A
    # if there's another pattern B such that:
    #   - A's shape appears as a sub-shape inside B's shape, AND
    #   - A.count == B.count, AND
    #   - every file in A.occurrences is also in B.occurrences
    #
    # Equal-count + file-containment is a strong signal that A's
    # occurrences are exactly the children of B's occurrences — not a
    # distinct repeated structure.
    def dedupe_nested(patterns)
      shape_to_pattern = patterns.to_h { |p| [p.shape, p] }
      patterns.reject do |inner|
        patterns.any? do |outer|
          next false if outer.equal?(inner)
          next false unless outer.count == inner.count
          next false unless outer.size > inner.size
          next false unless contains_subshape?(outer.shape, inner.shape)

          outer_files = outer.occurrences.map(&:file).to_set
          inner.occurrences.all? { |o| outer_files.include?(o.file) }
        end
      end
    end

    # True if `outer` contains `inner` as a proper child sub-shape — i.e.
    # `inner` appears inside `outer` bounded by `(` / `,` / `)`. This
    # avoids false matches like `tr` matching the middle of `strong`.
    def contains_subshape?(outer, inner)
      idx = 0
      while (i = outer.index(inner, idx))
        before = i.zero? ? nil : outer[i - 1]
        after = outer[i + inner.length]
        return true if [nil, "(", ","].include?(before) && [")", ","].include?(after)

        idx = i + 1
      end
      false
    end

    def view_files
      paths = VIEW_PATTERNS.flat_map { |g| Dir.glob(@root.join(g)) }.map { |p| Pathname(p) }.uniq
      paths.reject { |p| ignored?(p) }
    end

    def ignored?(path)
      segments = path.relative_path_from(@root).to_s.split("/")
      return true if (IMPLICIT_IGNORE_SEGMENTS & segments).any?

      segments.any? { |seg| IMPLICIT_IGNORE_PATTERNS.any? { |pat| seg.match?(pat) } }
    end

    # Walk the document yielding every HTMLElementNode subtree with its
    # computed fingerprint. Recurses into element bodies so nested
    # subtrees are reported alongside their parents.
    def walk_subtrees(node, &block)
      if node.is_a?(::Herb::AST::HTMLElementNode)
        fingerprint, shape, size = compute_subtree(node)
        yield node, fingerprint, shape, size if fingerprint

        Array(node.body).each { |child| walk_subtrees(child, &block) }
      else
        # DocumentNode and other non-element wrappers — descend into
        # children but don't yield for them.
        ErbParser.compact_children(node).each { |child| walk_subtrees(child, &block) }
      end
    end

    # Build a recursive shape string for an element subtree.
    #
    #   <div><h2>x</h2><p>y</p></div>  →  shape "div(h2,p)", size 3
    #
    # Returns [fingerprint, shape, size] — fingerprint is a short SHA
    # hash of the shape (cheap to compare, bounded memory). Size counts
    # element nodes; text and ERB don't contribute.
    def compute_subtree(node)
      return [nil, "", 0] unless node.is_a?(::Herb::AST::HTMLElementNode)

      tag = element_tag_name(node)
      return [nil, "", 0] if tag.nil?

      child_results = Array(node.body)
                      .map { |c| compute_subtree(c) }
                      .reject { |fp, _, _| fp.nil? }
      child_shapes = child_results.map { |_, sh, _| sh }
      child_size = child_results.sum { |_, _, sz| sz }

      shape = child_shapes.empty? ? tag : "#{tag}(#{child_shapes.join(',')})"
      fingerprint = Digest::SHA256.hexdigest(shape)[0, 16]

      [fingerprint, shape, child_size + 1]
    end

    def element_tag_name(element)
      return nil unless element.respond_to?(:open_tag) && element.open_tag

      tok = element.open_tag.tag_name
      tok && tok.respond_to?(:value) ? tok.value.to_s.downcase : nil
    end

    def print_report(patterns)
      return if patterns.empty?

      total_occurrences = patterns.sum(&:count)
      noun = patterns.length == 1 ? "shape" : "shapes"
      @output.puts ""
      @output.puts "Guardrails patterns: #{patterns.length} recurring #{noun} " \
                   "(#{total_occurrences} occurrences; >= #{@min_size} elements, >= #{@min_occurrences} occurrences)"

      patterns.each do |pattern|
        @output.puts ""
        @output.puts "  Pattern (#{pattern.size} elements, #{pattern.count} occurrences): #{truncate_shape(pattern.shape)}"
        pattern.occurrences.first(@max_occurrences_shown).each do |occ|
          @output.puts "    #{occ.file}:#{occ.line}"
        end
        if pattern.occurrences.length > @max_occurrences_shown
          remaining = pattern.occurrences.length - @max_occurrences_shown
          @output.puts "    … and #{remaining} more"
        end
      end
    end

    # Cap shape display length so deep nested patterns don't blow out
    # the terminal. The fingerprint is what we match on; the shape is
    # just for human inspection.
    def truncate_shape(shape, limit: 120)
      return shape if shape.length <= limit

      "#{shape[0, limit - 3]}..."
    end
  end
end
