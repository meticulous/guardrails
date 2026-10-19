# frozen_string_literal: true

require "pathname"
require "prism"

module Guardrails
  module FeedRamp
    # One Ruby file read with Prism, which ships with Ruby 3.4, so
    # discovery parses the app's classes instead of loading them: no
    # boot, no new dependency, and the same answer every time.
    class RubySource
      # A class definition. `name` is its full constant path; `scopes`
      # are the namespaces a constant inside its body is looked up in,
      # innermost last (so they end with `name` itself).
      ClassInfo = Struct.new(:name, :superclass, :scopes, :file, :node, :source, keyword_init: true) do
        def line
          node.location.start_line
        end

        # Scopes a constant in the class line itself (the superclass) is
        # looked up in: the enclosing ones, not the class's own.
        def outer_scopes
          scopes[0...-1]
        end

        def statements
          body = node.body
          body.is_a?(Prism::StatementsNode) ? body.body : []
        end

        def doc
          source.doc(line)
        end
      end

      # A comment block: prose lines, and `@tag rest` lines (YARD tags,
      # Lookbook annotations) as [tag, rest] pairs, in order.
      Doc = Struct.new(:text, :tags, keyword_init: true) do
        def tag(name)
          tags.find { |tag, _| tag == name }&.last
        end

        def tagged(name)
          tags.select { |tag, _| tag == name }.map(&:last)
        end
      end

      MAGIC_COMMENT = /\A#\s*(?:frozen_string_literal|encoding|rubocop:|typed:)/

      attr_reader :file, :text, :classes

      def initialize(path, root:)
        @file = Pathname(path).relative_path_from(Pathname(root)).to_s
        @text = File.read(path, encoding: Encoding::UTF_8)
        result = Prism.parse(@text)
        @lines = @text.lines
        @comments = result.comments.each_with_object({}) do |comment, by_line|
          line = comment.location.start_line
          by_line[line] = comment.slice if @lines[line - 1].to_s.lstrip.start_with?("#")
        end
        @classes = []
        collect_classes(result.value, [])
      end

      # The comment block directly above `line`, magic comments left out.
      def doc(line)
        lines = []
        current = line - 1
        while (comment = @comments[current])
          lines.unshift(comment) unless comment.match?(MAGIC_COMMENT)
          current -= 1
        end
        RubySource.parse_doc(lines)
      end

      def self.parse_doc(comments)
        text = []
        tags = []
        comments.each do |comment|
          line = comment.sub(/\A#+ ?/, "").rstrip
          if (tag = line.match(/\A@(\w+)\s*(.*)\z/))
            tags << [tag[1], tag[2]]
          else
            text << line
          end
        end
        Doc.new(text: text.join("\n").strip, tags: tags)
      end

      # A method's or lambda's parameters as plain data, defaults as
      # their source text.
      def self.params(node)
        node = node.parameters if node.is_a?(Prism::BlockParametersNode)
        return [] unless node.is_a?(Prism::ParametersNode)

        list = node.requireds.map { |p| param(p, "positional", true) }
        list += node.optionals.map { |p| param(p, "positional", false, p.value.slice) }
        list << param(node.rest, "rest", false) if node.rest.is_a?(Prism::RestParameterNode)
        list += node.posts.map { |p| param(p, "positional", true) }
        list += node.keywords.map do |p|
          p.is_a?(Prism::OptionalKeywordParameterNode) ? param(p, "keyword", false, p.value.slice) : param(p, "keyword", true)
        end
        list << param(node.keyword_rest, "keyrest", false) if node.keyword_rest.is_a?(Prism::KeywordRestParameterNode)
        list << param(node.block, "block", false) if node.block
        list
      end

      def self.param(node, kind, required, default = nil)
        name = node.respond_to?(:name) ? node.name&.to_s : nil
        { "name" => name || node.slice, "kind" => kind, "required" => required, "default" => default }
      end

      # The public instance methods defined in a class body, in order.
      # Tracks bare `private` / `protected` / `public` and `private def`.
      def self.public_methods(info)
        visibility = :public
        info.statements.each_with_object([]) do |node, defs|
          case node
          when Prism::DefNode
            defs << node if visibility == :public && node.receiver.nil?
          when Prism::CallNode
            next unless node.receiver.nil? && %i[private protected public].include?(node.name)

            if node.arguments.nil?
              visibility = node.name
            elsif node.name == :public
              defs.concat(node.arguments.arguments.grep(Prism::DefNode))
            end
          end
        end
      end

      # The written name of a constant reference, without a leading `::`.
      def self.constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then node.full_name.delete_prefix("::")
        end
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        nil
      end

      # Verbatim source of a node, its continuation lines dedented by the
      # column it starts at.
      def self.excerpt(node)
        indent = node.location.start_column
        first, *rest = node.slice.lines
        ([first] + rest.map { |line| line.sub(/\A {0,#{indent}}/, "") }).join.rstrip
      end

      private

      def collect_classes(node, scopes)
        case node
        when Prism::ClassNode
          name = qualified(node.constant_path, scopes)
          if name
            superclass = node.superclass && RubySource.constant_name(node.superclass)
            @classes << ClassInfo.new(name: name, superclass: superclass, scopes: scopes + [name],
                                      file: @file, node: node, source: self)
            scopes += [name]
          end
        when Prism::ModuleNode
          name = qualified(node.constant_path, scopes)
          scopes += [name] if name
        end
        node.compact_child_nodes.each { |child| collect_classes(child, scopes) }
      end

      def qualified(constant_path, scopes)
        written = RubySource.constant_name(constant_path)
        return nil unless written
        return written if constant_path.is_a?(Prism::ConstantPathNode) && constant_path.parent.nil?

        [scopes.last, written].compact.join("::")
      end
    end

    # Every class in a set of files, for resolving superclasses and
    # constant references across them the way Ruby's lexical lookup
    # would: innermost enclosing namespace first, then outward.
    class ClassIndex
      include Enumerable

      def initialize(sources)
        @classes = {}
        sources.flat_map(&:classes).each { |info| @classes[info.name] ||= info }
      end

      def each(&)
        @classes.each_value(&)
      end

      def [](name)
        @classes[name]
      end

      def key?(name)
        @classes.key?(name)
      end

      # The full name `written` refers to from inside `scopes`: a class
      # in the index when one matches, else `written` as is (a library
      # constant like ViewComponent::Base).
      def resolve(written, scopes)
        scopes.reverse_each do |scope|
          candidate = "#{scope}::#{written}"
          return candidate if @classes.key?(candidate)
        end
        written
      end

      def superclass_of(info)
        info.superclass && resolve(info.superclass, info.outer_scopes)
      end

      # Resolved superclass names, nearest first, ending at the first
      # one outside the index.
      def ancestors(info)
        chain = []
        current = info
        while current && (parent = superclass_of(current)) && !chain.include?(parent)
          chain << parent
          current = @classes[parent]
        end
        chain
      end
    end
  end
end
