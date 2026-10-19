# frozen_string_literal: true

require "prism"
require_relative "../erb_parser"

module Guardrails
  module FeedRamp
    # The outermost element a component renders, as its tag and static
    # classes: what hand-written markup copying the component looks like.
    # Read from the ERB template, or from the first tag a Phlex
    # `view_template` (or a ViewComponent `call`) builds with a literal
    # `class:`. nil when there's no such element to read.
    module RootElement
      # Tags Phlex and `tag.<name>` build that are worth matching.
      HTML_TAGS = %w[a article aside button details dialog div fieldset figure footer form h1 h2 h3 h4 h5 h6
                     header img input label li main nav ol p section select span summary table textarea ul].freeze
      RENDER_METHODS = %i[view_template template call].freeze

      module_function

      def for(component, root)
        element = if component.template&.end_with?(".erb")
                    from_erb(root.join(component.template).read)
                  else
                    from_ruby(component.info)
                  end
        element && { "tag" => element[0], "classes" => element[1] }
      rescue SystemCallError
        nil
      end

      def from_erb(source)
        node = ErbParser.each_node(ErbParser.parse(source).document).find { |n| n.is_a?(::Herb::AST::HTMLElementNode) }
        tag = node && ErbParser.tag_name(node)
        tag && [tag, ErbParser.static_classes(node)]
      end

      def from_ruby(info)
        method = info.statements.find { |node| node.is_a?(Prism::DefNode) && RENDER_METHODS.include?(node.name) }
        return nil unless method&.body

        first_tag_call(method.body)
      end

      # [tag, classes] for the first `div(class: "...")`,
      # `tag.div(class: "...")` or `content_tag(:div, class: "...")`.
      def first_tag_call(node)
        if node.is_a?(Prism::CallNode)
          tag = tag_of(node)
          return [tag, class_argument(node)] if tag
        end
        node.compact_child_nodes.each do |child|
          found = first_tag_call(child)
          return found if found
        end
        nil
      end

      def tag_of(call)
        name = call.name.to_s
        if call.receiver.nil? && HTML_TAGS.include?(name)
          name
        elsif call.receiver.is_a?(Prism::CallNode) && call.receiver.name == :tag && call.receiver.receiver.nil? &&
              HTML_TAGS.include?(name)
          name
        elsif call.receiver.nil? && name == "content_tag" && call.arguments&.arguments&.first.is_a?(Prism::SymbolNode)
          tag = call.arguments.arguments.first.unescaped
          tag if HTML_TAGS.include?(tag)
        end
      end

      def class_argument(call)
        (call.arguments&.arguments || []).each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          pair = arg.elements.find { |el| el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && el.key.unescaped == "class" }
          case (value = pair&.value)
          when Prism::StringNode then return ErbParser.class_tokens([value.unescaped])
          when Prism::InterpolatedStringNode
            return ErbParser.class_tokens(value.parts.map { |part| part.is_a?(Prism::StringNode) ? part.unescaped : nil })
          end
        end
        []
      end
    end
  end
end
