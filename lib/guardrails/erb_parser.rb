# frozen_string_literal: true

require "herb"

module Guardrails
  # Thin wrapper around the Herb ERB parser. Centralizes the call so:
  #
  #  - Detectors get a stable interface even if Herb's API drifts
  #  - Parse failures degrade gracefully (return an empty document
  #    rather than crashing the whole audit)
  #  - Future caching / incremental-parse hooks have a single point
  #    of attachment
  #
  # Detectors should walk `result.document`, an `Herb::AST::DocumentNode`.
  # Position info on every node is `node.location`, which exposes a
  # `start { line, column }` and `end { line, column }` (1-indexed lines,
  # 0-indexed columns from Herb).
  module ErbParser
    Result = Struct.new(:document, :errors, :source, keyword_init: true) do
      def success?
        errors.nil? || errors.empty?
      end
    end

    module_function

    # Parse ERB source text. Returns a Result regardless of parse success
    # — Herb crashes or value-less results both degrade to a safe
    # empty-document Result so callers can always traverse `result.document`
    # without nil-checking. Callers that care about strictness should check
    # `result.success?` and inspect `result.errors`.
    def parse(source)
      herb_result = Herb.parse(source)
      document = herb_result.value
      if document.nil?
        empty_result(source, ["herb returned no document for source"])
      else
        Result.new(
          document: document,
          errors: Array(herb_result.errors),
          source: source
        )
      end
    rescue StandardError => e
      empty_result(source, ["#{e.class}: #{e.message}"])
    end

    # Build a Result around an empty parsed document so detectors that
    # walk `result.document` see no elements rather than crashing.
    def empty_result(source, errors)
      empty = Herb.parse("")
      Result.new(document: empty.value, errors: Array(errors), source: source)
    rescue StandardError
      # If Herb can't even parse "", give back a Result whose document
      # responds to compact_child_nodes with []. Use a Struct-as-stub.
      Result.new(document: NULL_DOCUMENT, errors: Array(errors), source: source)
    end

    NULL_DOCUMENT = Struct.new(:compact_child_nodes, :children, :location).new([], [], nil)
    private_constant :NULL_DOCUMENT

    # Walk an AST node depth-first, yielding each descendant (including
    # the root). Callers filter by `node.class` or `node.tag_name`.
    def each_node(node, &block)
      return enum_for(:each_node, node) unless block_given?

      yield node
      compact_children(node).each { |child| each_node(child, &block) }
    end

    # Herb nodes expose either `compact_child_nodes` (preferred — skips
    # nils and unwraps single-child wrappers) or just `children`.
    def compact_children(node)
      if node.respond_to?(:compact_child_nodes)
        Array(node.compact_child_nodes)
      elsif node.respond_to?(:children)
        Array(node.children)
      else
        []
      end
    end

    # An element's tag name, downcased, or nil.
    def tag_name(element)
      return nil unless element.respond_to?(:open_tag) && element.open_tag

      tok = element.open_tag.tag_name
      tok.respond_to?(:value) ? tok.value.to_s.downcase : nil
    end

    # The static portion of an element's `class` attribute, as sorted,
    # unique tokens. ERB fragments inside the attribute are dropped (we
    # can't know what they'll render); a missing or ERB-only attribute
    # gives [].
    def static_classes(element)
      attr = attribute(element, "class")
      return [] unless attr

      _name_wrapper, value_wrapper = compact_children(attr)
      return [] unless value_wrapper

      pieces = compact_children(value_wrapper).map do |child|
        next nil unless child.is_a?(::Herb::AST::LiteralNode)

        content = child.content
        content.respond_to?(:value) ? content.value.to_s : content.to_s
      end
      class_tokens(pieces)
    end

    # Class tokens from a value written in pieces: strings, and nil for
    # each dynamic part. A token touching a dynamic part (`btn--` in
    # `btn--<%= variant %>`) isn't a class anyone can know, so it's left
    # out.
    def class_tokens(pieces)
      pieces.map { |piece| piece.nil? ? "\0" : piece.delete("\0") }.join
            .split(/\s+/).reject { |token| token.empty? || token.include?("\0") }.sort.uniq
    end

    # An element's attribute node by name, or nil.
    def attribute(element, name)
      return nil unless element.respond_to?(:open_tag) && element.open_tag

      compact_children(element.open_tag).find do |child|
        next false unless child.is_a?(::Herb::AST::HTMLAttributeNode)

        name_wrapper, _value_wrapper = compact_children(child)
        literal = name_wrapper && compact_children(name_wrapper).first
        next false unless literal.respond_to?(:content)

        text = literal.content.respond_to?(:value) ? literal.content.value.to_s : literal.content.to_s
        text.downcase == name
      end
    end

    # Convert a Herb location to (line, column) for a node's start.
    # Herb uses 1-indexed lines and 0-indexed columns; Guardrails violations
    # use 1-indexed columns. This adjusts for that.
    def start_position(node)
      loc = node.location
      [loc.start.line, loc.start.column + 1]
    end
  end
end
