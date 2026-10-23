# frozen_string_literal: true

require "prism"
require_relative "../erb_parser"

module Guardrails
  module FeedRamp
    # The outermost element a component renders, as its tag and the
    # classes it always has: what hand-written markup copying the
    # component looks like. Read from the ERB template, or from the first
    # tag a Phlex `view_template` (or a ViewComponent `call`) builds.
    #
    # Classes are read without rendering. A `class:` built by a helper
    # (`class_names("kbd", "kbd--bare": @bare)`, `build_css("button", …)`)
    # gives its unconditional string arguments; a method in the component
    # or its ancestors (`class: css_classes`, `**wrapper_attributes`,
    # `attrs[:class] = …`) is followed a few calls deep. A tag picked at
    # runtime (`content_tag(@tag, …)`) is the `tag:` default in
    # `initialize`, or nil when there's none. The whole result is nil when
    # there's no element to read.
    class RootElement
      # Elements a template, `tag.<name>` or Phlex can build.
      HTML_TAGS = %w[a abbr address article aside audio b bdi bdo blockquote body br button canvas caption cite code col
                     colgroup data datalist dd del details dfn dialog div dl dt em fieldset figcaption figure footer form
                     h1 h2 h3 h4 h5 h6 header hgroup hr i iframe img input ins kbd label legend li main mark menu meter
                     nav ol optgroup option output p picture pre progress q s samp search section select small span
                     strong sub summary sup svg table tbody td template textarea tfoot th thead time tr u ul var video].freeze
      # Rails helpers that build one element and put `class:` on it.
      HELPER_TAGS = {
        "link_to" => "a", "button_to" => "button", "button_tag" => "button", "label_tag" => "label",
        "select_tag" => "select", "text_area_tag" => "textarea", "submit_tag" => "input",
        **%w[text email password search number telephone url date color range].to_h { |kind| ["#{kind}_field_tag", "input"] }
      }.freeze
      RENDER_METHODS = %i[view_template template call].freeze
      # Calls that pass a string or hash through without changing which
      # classes it holds.
      PASS_THROUGH = %i[compact dup freeze presence to_s strip squish join uniq flatten html_safe tap].freeze
      HASH_MERGES = %i[merge merge! reverse_merge with_defaults deep_merge].freeze
      MAX_DEPTH = 4

      def self.for(component, root, index: nil)
        new(component, index: index).read(root)
      rescue SystemCallError
        nil
      end

      def initialize(component, index: nil)
        @component = component
        infos = [component.info]
        infos += index.ancestors(component.info).filter_map { |name| index[name] } if index
        @defs = {}
        @constants = {}
        infos.reverse_each { |info| collect(info.statements) } # the component's own win
      end

      def read(root)
        element = if @component.template&.end_with?(".erb")
                    from_erb(root.join(@component.template).read)
                  else
                    from_ruby
                  end
        element && { "tag" => element[0], "classes" => element[1] }
      end

      # The first element, or the first output tag building one
      # (`<%= tag.div class: classes do %>`); nil when the template starts
      # with output that isn't a tag.
      def from_erb(source)
        ErbParser.each_node(ErbParser.parse(source).document) do |node|
          return erb_element(node) if node.is_a?(::Herb::AST::HTMLElementNode)
          next unless output_tag?(node)

          ruby = erb_ruby(node.content.value.to_s)
          return ruby && first_tag_call(ruby, 0)
        end
        nil
      end

      def from_ruby
        method = RENDER_METHODS.filter_map { |name| @defs[name] }.first
        method&.body && first_tag_call(method.body, 0)
      end

      private

      def collect(statements)
        statements.each do |node|
          case node
          when Prism::DefNode then @defs[node.name] = node if node.receiver.nil?
          when Prism::ConstantWriteNode then @constants[node.name] = node.value
          when Prism::CallNode # `private def x`
            collect(node.arguments.arguments) if node.receiver.nil? && node.arguments
          end
        end
      end

      def output_tag?(node)
        (node.is_a?(::Herb::AST::ERBContentNode) || node.is_a?(::Herb::AST::ERBBlockNode)) &&
          node.tag_opening&.value.to_s.start_with?("<%=")
      end

      # The Ruby in an output tag; an opening `tag.div ... do` is closed
      # so it parses.
      def erb_ruby(code)
        [code, "#{code}\nend"].each do |attempt|
          result = Prism.parse(attempt)
          return result.value if result.errors.empty?
        end
        nil
      end

      def erb_element(element)
        tag = ErbParser.tag_name(element)
        return nil unless tag

        class_attr = ErbParser.attribute(element, "class")
        classes = class_attr ? erb_class_value(class_attr) : []
        # `<article <%= tag.attributes(**wrapper_attributes) %>>`
        if classes.empty?
          inside_class = class_attr ? ErbParser.each_node(class_attr).to_a : []
          ErbParser.each_node(element.open_tag).each do |node|
            next unless node.is_a?(::Herb::AST::ERBContentNode) && !inside_class.include?(node)

            ruby = erb_ruby(node.content.value.to_s)
            classes = ruby ? tag_call_classes(ruby, 0) : []
            break if classes.any?
          end
        end
        [tag, classes]
      end

      # `class="card <%= extra %>"`: the literal classes, plus what an
      # ERB fragment standing alone between spaces always gives.
      def erb_class_value(attr)
        value = ErbParser.compact_children(attr)[1]
        return [] unless value

        children = ErbParser.compact_children(value)
        pieces = children.map { |child| child.is_a?(::Herb::AST::LiteralNode) ? literal(child) : nil }
        tokens = ErbParser.class_tokens(pieces)
        children.each_with_index do |child, i|
          next unless child.is_a?(::Herb::AST::ERBContentNode)
          alone = (i.zero? || pieces[i - 1].to_s.match?(/\s\z/)) &&
                  (i == children.length - 1 || pieces[i + 1].to_s.match?(/\A\s/))
          next unless alone

          ruby = erb_ruby(child.content.value.to_s)
          tokens |= class_tokens(ruby.statements.body.last, 0) if ruby&.statements&.body&.any?
        end
        tokens.sort
      end

      def literal(node)
        node.content.respond_to?(:value) ? node.content.value.to_s : node.content.to_s
      end

      # [tag, classes] for the first tag-building call under `node`,
      # following calls to the component's own methods.
      def first_tag_call(node, depth, seen = Set.new)
        if node.is_a?(Prism::CallNode)
          if (tag = tag_of(node))
            return [tag == :dynamic ? nil : tag, call_classes(node, depth)]
          end
          if (method = own_method(node)) && depth < MAX_DEPTH && seen.add?(node.name)
            found = method.body && first_tag_call(method.body, depth + 1, seen)
            return found if found
          end
        end
        node.compact_child_nodes.each do |child|
          found = first_tag_call(child, depth, seen)
          return found if found
        end
        nil
      end

      # The classes from the first call under `node` that takes `class:`
      # or a splatted attributes hash.
      def tag_call_classes(node, depth)
        if node.is_a?(Prism::CallNode)
          classes = call_classes(node, depth)
          return classes if classes.any?
        end
        node.compact_child_nodes.each do |child|
          classes = tag_call_classes(child, depth)
          return classes if classes.any?
        end
        []
      end

      # The tag a call builds, :dynamic when it's chosen at runtime, or
      # nil when the call doesn't build one.
      def tag_of(call)
        name = call.name.to_s
        if call.receiver.nil? && HTML_TAGS.include?(name) && @component.kind == "phlex" && !@defs.key?(call.name)
          name
        elsif call.receiver.is_a?(Prism::CallNode) && call.receiver.name == :tag && call.receiver.receiver.nil? &&
              HTML_TAGS.include?(name)
          name
        elsif call.receiver.nil? && HELPER_TAGS.key?(name)
          HELPER_TAGS[name]
        elsif call.receiver.nil? && name == "content_tag"
          first = call.arguments&.arguments&.first
          tag = first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode) ? first.unescaped : tag_default(first)
          tag.nil? ? :dynamic : (tag if HTML_TAGS.include?(tag))
        end
      end

      # `content_tag(@tag, …)` / `content_tag(tag, …)`: the symbol
      # default of the `initialize` keyword of that name.
      def tag_default(node)
        name = case node
               when Prism::InstanceVariableReadNode then node.name.to_s.delete_prefix("@")
               when Prism::LocalVariableReadNode then node.name.to_s
               when Prism::CallNode then node.name.to_s if node.receiver.nil? && node.arguments.nil?
               end
        params = @defs[:initialize]&.parameters
        return nil unless name && params

        keyword = params.keywords.find { |p| p.name.to_s == name && p.is_a?(Prism::OptionalKeywordParameterNode) }
        keyword.value.unescaped if keyword&.value.is_a?(Prism::SymbolNode)
      end

      # Classes a tag call is given: its `class:`, or one in a splatted
      # or positional attributes hash.
      def call_classes(call, depth)
        (call.arguments&.arguments || []).reverse_each do |arg| # the last `class:` wins
          classes = hash_classes(arg, depth)
          return classes if classes
        end
        []
      end

      # The classes a hash expression's `class:` always holds, or nil when
      # it has no `class:` that can be found.
      def hash_classes(node, depth)
        return nil if depth > MAX_DEPTH

        case node
        when Prism::HashNode, Prism::KeywordHashNode
          node.elements.reverse_each do |element|
            case element
            when Prism::AssocNode
              return class_tokens(element.value, depth) if class_key?(element.key)
            when Prism::AssocSplatNode
              found = hash_classes(element.value, depth)
              return found if found
            end
          end
          nil
        when Prism::AssocSplatNode then hash_classes(node.value, depth)
        when Prism::ParenthesesNode then hash_classes(node.body&.body&.last, depth)
        when Prism::StatementsNode then hash_classes(node.body.last, depth)
        when Prism::CallNode then call_hash_classes(node, depth)
        end
      end

      def call_hash_classes(call, depth)
        if (method = own_method(call))
          return method_hash_classes(method, depth + 1)
        end
        if call.receiver && (HASH_MERGES.include?(call.name) || PASS_THROUGH.include?(call.name))
          from_args = HASH_MERGES.include?(call.name) ? call_classes(call, depth) : []
          return from_args.any? ? from_args : hash_classes(call.receiver, depth)
        end
        # `html_options(class: "tabs", …)`: a helper given the classes.
        classes = call_classes(call, depth)
        classes.any? ? classes : nil
      end

      # A method building an attributes hash: an `attrs[:class] = …` in its
      # body, or the hash it returns.
      def method_hash_classes(method, depth)
        assignment = find_node(method.body) do |node|
          node.is_a?(Prism::CallNode) && node.name == :[]= && class_key?(node.arguments&.arguments&.first)
        end
        return class_tokens(assignment.arguments.arguments[1], depth) if assignment

        hash_classes(last_expression(method), depth)
      end

      # The classes a `class:` value always gives.
      def class_tokens(node, depth)
        return [] if depth > MAX_DEPTH

        case node
        when Prism::StringNode then ErbParser.class_tokens([node.unescaped])
        when Prism::InterpolatedStringNode
          ErbParser.class_tokens(node.parts.map { |part| part.is_a?(Prism::StringNode) ? part.unescaped : nil })
        when Prism::ArrayNode then literal_args(node.elements, depth)
        when Prism::ConstantReadNode then @constants[node.name] ? class_tokens(@constants[node.name], depth + 1) : []
        when Prism::CallNode then call_class_tokens(node, depth)
        else []
        end
      end

      def call_class_tokens(call, depth)
        if (method = own_method(call))
          class_tokens(last_expression(method), depth + 1)
        elsif call.receiver && PASS_THROUGH.include?(call.name)
          class_tokens(call.receiver, depth)
        elsif call.receiver.nil?
          # `class_names("kbd", "kbd--bare": @bare)`, `build_css("button", …)`
          literal_args(call.arguments&.arguments || [], depth)
        else
          []
        end
      end

      # Classes from the unconditional strings (and arrays of them) in a
      # list; conditionals and hashes are left out.
      def literal_args(nodes, depth)
        nodes.flat_map do |node|
          case node
          when Prism::StringNode, Prism::InterpolatedStringNode, Prism::ArrayNode then class_tokens(node, depth)
          else []
          end
        end.uniq.sort
      end

      # A receiver-less, argument-less call to a method the component (or
      # an ancestor in the app) defines.
      def own_method(call)
        return nil unless call.receiver.nil? && call.arguments.nil? && call.block.nil?

        method = @defs[call.name]
        method if method && method.parameters.nil?
      end

      def last_expression(method)
        body = method.body
        body = body.statements if body.is_a?(Prism::BeginNode)
        body.is_a?(Prism::StatementsNode) ? body.body.last : body
      end

      def class_key?(node)
        (node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)) && node.unescaped == "class"
      end

      def find_node(node, &block)
        return nil unless node
        return node if yield(node)

        node.compact_child_nodes.each do |child|
          found = find_node(child, &block)
          return found if found
        end
        nil
      end
    end
  end
end
