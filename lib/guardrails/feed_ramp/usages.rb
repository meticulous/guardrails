# frozen_string_literal: true

require "pathname"
require "prism"
require_relative "../audit"
require_relative "../erb_parser"
require_relative "ruby_source"

module Guardrails
  module FeedRamp
    # Where the app renders its components: `render XComponent.new(...)`
    # in previews, templates and Ruby views, and Phlex kit calls
    # (`Alert(tone: :warning)`, `Components::Alert(...)`) in Ruby views. Each component's example in
    # the manifest is one of these, copied from the source; nothing is
    # ever written for it.
    class Usages
      # `qualified` when the source names the component by its full name,
      # so the example works anywhere, not just inside its namespace.
      Usage = Struct.new(:component, :source, :file, :line, :from, :language, :qualified, keyword_init: true) do
        def to_h
          { "source" => source, "file" => file, "line" => line, "from" => from, "language" => language }
        end
      end

      VIEW_PATHS = %w[app/views].freeze

      def initialize(root:, config:, discovery:)
        @root = Pathname(root)
        @config = config
        @discovery = discovery
        @names = discovery.components.to_set(&:name)
        phlex = discovery.components.select { |c| c.kind == "phlex" }
        @phlex_names = phlex.to_set(&:name)
        @phlex_by_short_name = phlex.group_by { |c| c.name.split("::").last }
      end

      # Templates and Ruby views searched for call sites.
      def files
        @files ||= (VIEW_PATHS + @config.component_paths).uniq
                                                        .flat_map { |path| Dir.glob(@root.join(path, "**/*.{erb,rb}")) }
                                                        .uniq.sort.map { |path| Pathname(path).relative_path_from(@root).to_s }
                                                        .reject { |file| ignored?(file) }
      end

      # The shortest render of the component in a preview Lookbook shows,
      # or else the shortest call site; nil when the app never renders it.
      # One that names the component in full beats both, since an agent
      # can paste it into any view.
      def example_for(component)
        candidates = [preview_usages, call_sites].each_with_index.flat_map do |usages, rank|
          usages.select { |u| u.component == component.name }.map { |u| [u, rank] }
        end
        candidates.min_by { |u, rank| [u.qualified ? 0 : 1, rank, u.source.length, u.file, u.line] }&.first
      end

      def preview_usages
        @preview_usages ||= @discovery.previews.flat_map do |preview|
          preview.methods.reject { |method| preview.info.source.doc(method.location.start_line).tag("hidden") }
                 .flat_map { |method| ruby_renders(method, preview.info.scopes, preview.info.file, "preview") }
        end
      end

      def call_sites
        @call_sites ||= files.flat_map do |file|
          file.end_with?(".erb") ? erb_renders(file) : ruby_file_renders(file)
        end
      end

      private

      def ignored?(file)
        segments = file.split("/")
        (Audit::IMPLICIT_IGNORE & segments).any? || @discovery.preview_paths.any? { |path| file.start_with?("#{path}/") }
      end

      # `render X.new(...)` calls under `node`, with constants resolved
      # from `scopes`.
      def ruby_renders(node, scopes, file, from)
        found = []
        walk(node, scopes) do |call, current_scopes|
          resolve = ->(constant) { @discovery.index.resolve(constant, current_scopes) }
          name, written = rendered_component(call, &resolve) || kit_component(call, &resolve)
          next unless name

          found << Usage.new(component: name, source: RubySource.excerpt(call), file: file, line: call.location.start_line,
                             from: from, language: "ruby", qualified: written == name)
        end
        found
      end

      def ruby_file_renders(file)
        ruby_renders(Prism.parse(File.read(@root.join(file), encoding: Encoding::UTF_8)).value, [], file, "call_site")
      end

      # Output tags (`<%= render X.new %>`, or a block through its `<% end %>`)
      # rendering a component, copied from the template with their tags.
      def erb_renders(file)
        text = File.read(@root.join(file), encoding: Encoding::UTF_8)
        lines = text.lines
        ErbParser.each_node(ErbParser.parse(text).document).filter_map do |node|
          next unless node.is_a?(Herb::AST::ERBContentNode) || node.is_a?(Herb::AST::ERBBlockNode)
          next unless node.tag_opening&.value.to_s.start_with?("<%=")

          call = Prism.parse(node.content.value.to_s).value.statements.body.first
          next unless call.is_a?(Prism::CallNode)

          name, = rendered_component(call) { |constant| constant }
          next unless name

          Usage.new(component: name, source: slice(lines, node.location), file: file,
                    line: node.location.start.line, from: "call_site", language: "erb", qualified: true)
        end
      end

      # [component, constant as written] for a `render X.new(...)` call
      # when X names a component; the block resolves the written name.
      def rendered_component(call)
        return nil unless call.name == :render && call.receiver.nil?

        built = call.arguments&.arguments&.first
        return nil unless built.is_a?(Prism::CallNode) && built.name == :new

        written = RubySource.constant_name(built.receiver)
        name = written && yield(written)
        [name, written] if @names.include?(name)
      end

      # [component, name as written] for a Phlex kit call: `Alert(...)`
      # in a view that includes the kit, or `Components::Alert(...)`.
      # A bare name is the one Phlex component with that name.
      def kit_component(call)
        return nil unless call.name.match?(/\A[A-Z]/)

        if call.receiver
          namespace = RubySource.constant_name(call.receiver)
          return nil unless namespace

          written = "#{namespace}::#{call.name}"
          name = yield(written)
        else
          written = call.name.to_s
          candidates = @phlex_by_short_name.fetch(written, [])
          name = candidates.first.name if candidates.length == 1
        end
        [name, written] if @phlex_names.include?(name)
      end

      def walk(node, scopes, &block)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          written = RubySource.constant_name(node.constant_path)
          scopes += [[scopes.last, written].compact.join("::")] if written
        when Prism::CallNode
          yield node, scopes
        end
        node.compact_child_nodes.each { |child| walk(child, scopes, &block) }
      end

      # Template text between two Herb positions (1-indexed lines,
      # 0-indexed columns, end exclusive), continuation lines dedented.
      def slice(lines, location)
        first = location.start.line - 1
        last = location.end.line - 1
        indent = location.start.column
        text = (first..last).map do |i|
          line = lines[i].to_s
          line = line[0, location.end.column] if i == last
          i == first ? line[indent..] : line.sub(/\A {0,#{indent}}/, "")
        end
        text.join.rstrip
      end
    end
  end
end
