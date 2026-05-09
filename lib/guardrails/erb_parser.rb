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

    # Parse ERB source text. Returns a Result regardless of parse success;
    # callers can check #success? if they care about strictness.
    def parse(source)
      herb_result = Herb.parse(source)
      Result.new(
        document: herb_result.value,
        errors: herb_result.errors,
        source: source
      )
    end

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

    # Convert a Herb location to (line, column) for a node's start.
    # Herb uses 1-indexed lines and 0-indexed columns; Guardrails violations
    # use 1-indexed columns. This adjusts for that.
    def start_position(node)
      loc = node.location
      [loc.start.line, loc.start.column + 1]
    end
  end
end
