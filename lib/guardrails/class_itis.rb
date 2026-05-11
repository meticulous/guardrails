# frozen_string_literal: true

require "pathname"
require_relative "erb_parser"
require_relative "report/style"

module Guardrails
  # Finds repeating "class soup" — the same long class list applied to
  # the same tag in many places. The classic AI-assisted-Rails failure
  # mode: a 6-utility `class="px-4 py-2 text-sm font-medium bg-white
  # rounded-md"` ends up copy-pasted onto 30 buttons because the
  # assistant doesn't know the codebase already has a `ButtonComponent`
  # or `.btn-base` class.
  #
  # Distinct from CrossCodebasePatterns (structural shape, ignores
  # classes) and PartialSimilarity (whole-partial Jaccard). This audit
  # looks at *single elements* whose class attribute is a repeated
  # high-cardinality literal — the cleanest signal for "extract a
  # ButtonComponent / use @apply / add a semantic class."
  class ClassItis
    Occurrence = Struct.new(:file, :line, :column, keyword_init: true)

    Cluster = Struct.new(:tag, :classes, :occurrences, keyword_init: true) do
      def count
        occurrences.length
      end

      def class_count
        classes.length
      end
    end

    # Below this many tokens in the class list, repetition is fine —
    # `<button class="primary">` everywhere is intentional, not soup.
    # Soup starts when 5+ classes pile up on one element with no
    # semantic name to anchor them.
    DEFAULT_MIN_CLASSES = 5

    # Same threshold as CrossCodebasePatterns — 2 occurrences are noise,
    # 3+ implies a real recurring pattern worth extracting.
    DEFAULT_MIN_OCCURRENCES = 3

    DEFAULT_MAX_OCCURRENCES_SHOWN = 10

    VIEW_PATTERNS = [
      "app/views/**/*.html.erb",
      "app/components/**/*.html.erb"
    ].freeze

    IMPLICIT_IGNORE_SEGMENTS = %w[vendor node_modules tmp public log].freeze
    IMPLICIT_IGNORE_PATTERNS = [/\A(?:\w+_)?mailer\z/].freeze

    def initialize(root:, output: $stdout,
                   min_classes: DEFAULT_MIN_CLASSES,
                   min_occurrences: DEFAULT_MIN_OCCURRENCES,
                   max_occurrences_shown: DEFAULT_MAX_OCCURRENCES_SHOWN,
                   style: nil)
      @root = Pathname(root)
      @output = output
      @min_classes = min_classes
      @min_occurrences = min_occurrences
      @max_occurrences_shown = max_occurrences_shown
      @style = style || Report::Style.new(io: output)
    end

    def run
      clusters = find_clusters
      print_report(clusters)
      clusters
    end

    def find_clusters
      groups = Hash.new { |h, k| h[k] = [] }

      view_files.each do |file|
        content = File.read(file, encoding: Encoding::UTF_8)
        result = ErbParser.parse(content)
        relative = file.relative_path_from(@root).to_s

        ErbParser.each_node(result.document) do |node|
          next unless node.is_a?(::Herb::AST::HTMLElementNode)

          tag = element_tag_name(node)
          next if tag.nil?

          classes = static_class_tokens(node)
          next if classes.length < @min_classes

          line, column = ErbParser.start_position(node)
          key = [tag, classes]
          groups[key] << Occurrence.new(file: relative, line: line, column: column)
        end
      end

      groups
        .select { |_, occs| occs.length >= @min_occurrences }
        .map { |(tag, classes), occs| Cluster.new(tag: tag, classes: classes, occurrences: occs) }
        .sort_by { |c| [-c.count, -c.class_count] }
    end

    private

    def view_files
      paths = VIEW_PATTERNS.flat_map { |g| Dir.glob(@root.join(g)) }.map { |p| Pathname(p) }.uniq
      paths.reject { |p| ignored?(p) }
    end

    def ignored?(path)
      segments = path.relative_path_from(@root).to_s.split("/")
      return true if (IMPLICIT_IGNORE_SEGMENTS & segments).any?

      segments.any? { |seg| IMPLICIT_IGNORE_PATTERNS.any? { |pat| seg.match?(pat) } }
    end

    def element_tag_name(element)
      return nil unless element.respond_to?(:open_tag) && element.open_tag

      tok = element.open_tag.tag_name
      tok && tok.respond_to?(:value) ? tok.value.to_s.downcase : nil
    end

    # Pull the static portion of the element's `class` attribute. If
    # the attribute is missing, ERB-driven, or empty, returns []. ERB
    # fragments inside a class attribute are dropped (we can't know
    # what they'll render); the literal pieces are concatenated and
    # whitespace-tokenized. Tokens are sorted so two identical lists
    # in different source order produce the same fingerprint key.
    def static_class_tokens(element)
      attr = class_attribute_node(element)
      return [] unless attr

      static = static_attribute_value(attr)
      return [] if static.nil? || static.strip.empty?

      static.split(/\s+/).reject(&:empty?).sort.uniq
    end

    def class_attribute_node(element)
      open_children = ErbParser.compact_children(element.open_tag)
      open_children.find do |child|
        next false unless child.is_a?(::Herb::AST::HTMLAttributeNode)

        name_wrapper, _value_wrapper = ErbParser.compact_children(child)
        next false unless name_wrapper

        literal = ErbParser.compact_children(name_wrapper).first
        next false unless literal && literal.respond_to?(:content)

        name = literal.content.respond_to?(:value) ? literal.content.value.to_s : literal.content.to_s
        name.downcase == "class"
      end
    end

    def static_attribute_value(attribute_node)
      _name_wrapper, value_wrapper = ErbParser.compact_children(attribute_node)
      return nil unless value_wrapper

      ErbParser.compact_children(value_wrapper).filter_map do |child|
        next unless child.is_a?(::Herb::AST::LiteralNode)

        content = child.content
        content.respond_to?(:value) ? content.value.to_s : content.to_s
      end.join
    end

    def print_report(clusters)
      return if clusters.empty?

      total_occurrences = clusters.sum(&:count)
      noun = clusters.length == 1 ? "cluster" : "clusters"

      @output.puts ""
      @output.puts @style.section_heading(
        :suggestion,
        "class-itis (#{clusters.length} #{noun}, #{total_occurrences} occurrences)"
      )
      @output.puts "  The same multi-class list applied to the same tag in many places —"
      @output.puts "  classic AI-paste pattern. Consider extracting a shared component or"
      @output.puts "  an @apply rule. Threshold: >= #{@min_classes} classes, >= #{@min_occurrences} occurrences."

      clusters.each do |cluster|
        @output.puts ""
        header = "<#{cluster.tag}> with #{cluster.class_count} classes, #{cluster.count} occurrences"
        @output.puts "  #{@style.severity(:suggestion, header)}"
        @output.puts "    #{@style.suggestion(suggestion_for(cluster))}"
        @output.puts "    class=#{format_classes(cluster.classes)}"
        cluster.occurrences.first(@max_occurrences_shown).each do |occ|
          @output.puts "    #{@style.location("#{occ.file}:#{occ.line}")}"
        end
        if cluster.occurrences.length > @max_occurrences_shown
          remaining = cluster.occurrences.length - @max_occurrences_shown
          @output.puts "    #{@style.location("… and #{remaining} more")}"
        end
      end
    end

    # Suggestion shape varies by cluster size + count. Big class lists
    # repeated many places want a component; smaller lists repeated
    # often might just be a shared CSS rule.
    def suggestion_for(cluster)
      if cluster.class_count >= 8
        "extract a #{component_name(cluster)} component — too many classes to keep inlined"
      elsif cluster.count >= 6
        "repeated this often, an @apply rule or shared class would dry it up"
      else
        "consider a shared component or @apply rule for this class list"
      end
    end

    def component_name(cluster)
      "#{cluster.tag.capitalize}Component"
    end

    # Cap the displayed class string so a 30-utility soup doesn't blow
    # out the terminal. Fingerprint matching is on the full sorted list,
    # so display truncation is purely cosmetic.
    def format_classes(classes, limit: 100)
      joined = classes.join(" ")
      str = joined.length <= limit ? joined : "#{joined[0, limit - 3]}..."
      "\"#{str}\""
    end
  end
end
