# frozen_string_literal: true

require "pathname"
require_relative "../audit"
require_relative "ruby_source"

module Guardrails
  module FeedRamp
    # Finds the app's ViewComponent and Phlex components, and the Lookbook
    # / ViewComponent previews for them, by parsing the files under the
    # configured paths. A class is a component when its superclass chain,
    # followed through the app's own classes (`ApplicationComponent`,
    # `Components::Base`), reaches one of the libraries' base classes;
    # neither library needs to be installed for that.
    class Discovery
      VIEW_COMPONENT_BASES = %w[ViewComponent::Base].freeze
      PHLEX_BASES = %w[Phlex::HTML Phlex::SVG].freeze
      PREVIEW_BASES = %w[ViewComponent::Preview Lookbook::Preview].freeze

      # Methods that make a class renderable on its own. A base class
      # without one (ApplicationComponent) isn't a component to offer.
      RENDER_METHODS = { "view_component" => %i[call], "phlex" => %i[view_template template] }.freeze

      # Phlex has no slot declarations; public methods taking a block
      # stand in for them, other than these.
      PHLEX_LIFECYCLE = %i[initialize view_template template before_template after_template around_template].freeze

      Component = Struct.new(:name, :kind, :info, :template, keyword_init: true) do
        def file
          info.file
        end
      end

      # `methods` are the preview's public instance methods, in order.
      Preview = Struct.new(:info, :component, :methods, keyword_init: true)

      attr_reader :index

      def initialize(root:, config:)
        @root = Pathname(root)
        @config = config
        @component_sources = ruby_sources(config.component_paths)
        @preview_sources = ruby_sources(config.preview_paths)
        @index = ClassIndex.new(@component_sources + @preview_sources)
      end

      def components
        @components ||= begin
          candidates = @component_sources.flat_map(&:classes).filter_map do |info|
            next unless @index[info.name].equal?(info)

            kind = kind_of(info)
            kind && Component.new(name: info.name, kind: kind, info: info, template: template_for(info))
          end
          parents = candidates.to_set { |c| @index.superclass_of(c.info) }
          candidates.reject { |c| parents.include?(c.name) && !renderable?(c) }.sort_by(&:name)
        end
      end

      def previews
        @previews ||= @preview_sources.flat_map(&:classes).filter_map do |info|
          next unless (@index.ancestors(info) & PREVIEW_BASES).any?

          component = component_for_preview(info)
          component && Preview.new(info: info, component: component, methods: RubySource.public_methods(info))
        end.sort_by { |p| [p.component.name, p.info.file] }
      end

      # The `initialize` a component is built with: its own, or the
      # nearest one it inherits from the app's classes.
      def constructor(component)
        ([component.info] + @index.ancestors(component.info).filter_map { |name| @index[name] }).each do |info|
          init = info.statements.find { |node| node.is_a?(Prism::DefNode) && node.name == :initialize && node.receiver.nil? }
          return [init, info] if init
        end
        nil
      end

      def params(component)
        init, owner = constructor(component)
        return [] unless init

        docs = param_docs(component.info.doc).merge(param_docs(owner.source.doc(init.location.start_line)))
        RubySource.params(init.parameters).map do |param|
          doc = docs[param["name"]]
          param.merge("type" => doc&.dig(:type), "description" => doc&.dig(:description))
        end
      end

      def slots(component)
        component.kind == "phlex" ? phlex_slots(component) : view_component_slots(component)
      end

      private

      def ruby_sources(paths)
        paths.flat_map { |path| Dir.glob(@root.join(path, "**/*.rb")) }.uniq.sort
             .reject { |path| (Audit::IMPLICIT_IGNORE & Pathname(path).relative_path_from(@root).to_s.split("/")).any? }
             .map { |path| RubySource.new(path, root: @root) }
      end

      def kind_of(info)
        ancestors = @index.ancestors(info)
        return "view_component" if ancestors.intersect?(VIEW_COMPONENT_BASES)

        "phlex" if ancestors.intersect?(PHLEX_BASES)
      end

      def renderable?(component)
        return true if component.template

        names = RENDER_METHODS.fetch(component.kind)
        component.info.statements.any? do |node|
          (node.is_a?(Prism::DefNode) && names.include?(node.name)) ||
            (node.is_a?(Prism::CallNode) && node.name == :erb_template)
        end
      end

      # A ViewComponent's sidecar template, `foo_component.html.erb` next
      # to the class or in a `foo_component/` directory beside it.
      def template_for(info)
        base = @root.join(info.file).sub_ext("")
        candidates = Dir.glob("#{base}.html.*") + Dir.glob(base.join("#{base.basename}.html.*").to_s)
        found = candidates.reject { |path| File.basename(path).include?("+") }.min
        found && Pathname(found).relative_path_from(@root).to_s
      end

      # `ButtonComponentPreview` previews `ButtonComponent`; Lookbook also
      # allows `ButtonPreview` for it. Any other name (`AlertPreview` for
      # `Components::Alert`) previews the component it builds most often.
      def component_for_preview(info)
        base = info.name.delete_suffix("Preview")
        names = components.to_h { |c| [c.name, c] }
        names[base] || names["#{base}Component"] || most_built(info, names)
      end

      def most_built(info, names)
        built = []
        each_node(info.node) do |node|
          next unless node.is_a?(Prism::CallNode) && node.name == :new

          written = RubySource.constant_name(node.receiver)
          name = written && @index.resolve(written, info.scopes)
          built << name if names.key?(name)
        end
        best = built.tally.min_by { |name, count| [-count, name] }
        best && names[best.first]
      end

      def each_node(node, &block)
        yield node
        node.compact_child_nodes.each { |child| each_node(child, &block) }
      end

      # `@param name [Type] description` tags from a YARD comment.
      def param_docs(doc)
        doc.tagged("param").each_with_object({}) do |rest, docs|
          match = rest.match(/\A(\w+)\s*(?:\[([^\]]*)\])?\s*(.*)\z/)
          docs[match[1]] = { type: match[2], description: match[3].empty? ? nil : match[3] } if match
        end
      end

      def view_component_slots(component)
        component.info.statements.filter_map do |node|
          next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[renders_one renders_many].include?(node.name)

          args = node.arguments&.arguments || []
          next unless args.first.is_a?(Prism::SymbolNode)

          slot = { "name" => args.first.unescaped, "kind" => node.name.to_s, "type" => nil, "params" => [], "heuristic" => false }
          case (target = args[1])
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            slot["type"] = RubySource.constant_name(target)
          when Prism::StringNode
            slot["type"] = target.unescaped
          when Prism::LambdaNode
            slot["type"] = "lambda"
            slot["params"] = RubySource.params(target.parameters)
          when Prism::KeywordHashNode
            types = target.elements.find { |el| el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && el.key.unescaped == "types" }
            if types
              slot["type"] = "polymorphic"
              slot["types"] = types.value.is_a?(Prism::HashNode) ? types.value.elements.filter_map { |el| el.key.unescaped if el.respond_to?(:key) && el.key.is_a?(Prism::SymbolNode) } : []
            end
          end
          slot
        end
      end

      def phlex_slots(component)
        RubySource.public_methods(component.info).filter_map do |node|
          next if PHLEX_LIFECYCLE.include?(node.name) || node.parameters&.block.nil?

          { "name" => node.name.to_s, "kind" => "block_method", "type" => nil,
            "params" => RubySource.params(node.parameters).reject { |p| p["kind"] == "block" }, "heuristic" => true }
        end
      end
    end
  end
end
