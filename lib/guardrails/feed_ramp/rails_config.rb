# frozen_string_literal: true

require "pathname"
require "prism"

module Guardrails
  module FeedRamp
    # Settings Feed Ramp needs from the app's Rails config, read with
    # Prism rather than by booting the app: the preview directories added
    # with
    #
    #     config.view_component.previews.paths << Rails.root.join("spec/components/previews").to_s
    #     config.view_component.preview_paths += ["#{Rails.root}/lib/previews"]
    #     config.lookbook.preview_paths = [File.expand_path("../previews", __dir__)]
    #
    # Only paths written as literals (or built from Rails.root, `root` or
    # `__dir__`) are found; anything computed at boot isn't.
    module RailsConfig
      FILES = %w[config/application.rb config/environments/development.rb config/environments/test.rb].freeze
      LIST_WRITES = %i[<< push append concat unshift prepend].freeze

      module_function

      # Preview directories relative to root, in the order the files set
      # them; none outside root.
      def preview_paths(root)
        root = Pathname(root)
        FILES.flat_map do |file|
          path = root.join(file)
          path.file? ? paths_in(Prism.parse(path.read).value, path.dirname, root) : []
        end.uniq
      rescue SystemCallError
        []
      end

      def paths_in(node, dir, root)
        found = []
        visit(node) do |target, values|
          next unless preview_setting?(target)

          found.concat(values.flat_map { |value| path_values(value, dir, root) })
        end
        found
      end

      # Yields [the setting's receiver chain, value nodes] for each write
      # to a setting: `a.b = v`, `a.b << v`, `a.b += [v]`, `a.b.concat([v])`.
      def visit(node, &block)
        case node
        when Prism::CallNode
          args = node.arguments&.arguments || []
          if node.name.end_with?("=") && !%i[== != === <= >= []=].include?(node.name) && node.receiver
            yield chain(node.receiver) + [node.name.to_s.chomp("=")], args
          elsif LIST_WRITES.include?(node.name) && node.receiver
            yield chain(node.receiver), args
          end
        when Prism::CallOperatorWriteNode
          yield chain(node.receiver) + [node.read_name.to_s], [node.value] if node.receiver
        end
        node.compact_child_nodes.each { |child| visit(child, &block) }
      end

      # `config.view_component.previews.paths` as its method names.
      def chain(node)
        names = []
        while node.is_a?(Prism::CallNode)
          names.unshift(node.name.to_s)
          node = node.receiver
        end
        names
      end

      def preview_setting?(names)
        (names.include?("view_component") || names.include?("lookbook")) &&
          (names.last == "preview_paths" || names.last(2) == %w[previews paths])
      end

      # The paths a value names: a string, a list of them, or one built
      # from Rails.root / __dir__.
      def path_values(node, dir, root)
        case node
        when Prism::ArrayNode then node.elements.flat_map { |element| path_values(element, dir, root) }
        else
          path = path_value(node, dir, root)
          path ? [path] : []
        end
      end

      def path_value(node, dir, root)
        absolute = case node
                   when Prism::StringNode then root.join(node.unescaped)
                   when Prism::InterpolatedStringNode then rails_root_string(node, root)
                   when Prism::CallNode then path_call(node, dir, root)
                   end
        return nil unless absolute

        relative = absolute.cleanpath.relative_path_from(root.cleanpath).to_s
        relative unless relative.start_with?("..")
      rescue ArgumentError
        nil
      end

      def path_call(call, dir, root)
        args = call.arguments&.arguments || []
        if %i[to_s to_path].include?(call.name) && call.receiver
          path_value_absolute(call.receiver, dir, root)
        elsif call.name == :join && rails_root?(call.receiver) && args.all?(Prism::StringNode)
          root.join(*args.map(&:unescaped))
        elsif call.name == :expand_path && call.receiver.is_a?(Prism::ConstantReadNode) && call.receiver.name == :File &&
              args.first.is_a?(Prism::StringNode)
          base = dir_call?(args[1]) ? dir : root
          base.join(args.first.unescaped)
        end
      end

      def path_value_absolute(node, dir, root)
        case node
        when Prism::CallNode then path_call(node, dir, root)
        when Prism::StringNode then root.join(node.unescaped)
        end
      end

      # `"#{Rails.root}/spec/previews"`
      def rails_root_string(node, root)
        first, *rest = node.parts
        return nil unless first.is_a?(Prism::EmbeddedStatementsNode) && rails_root?(first.statements&.body&.first)
        return nil unless rest.all?(Prism::StringNode)

        root.join(rest.map(&:unescaped).join.delete_prefix("/"))
      end

      # `Rails.root`, or `root` inside the Application class.
      def rails_root?(node)
        return false unless node.is_a?(Prism::CallNode) && node.name == :root && node.arguments.nil?

        node.receiver.nil? || (node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Rails)
      end

      def dir_call?(node)
        node.is_a?(Prism::CallNode) && node.name == :__dir__ && node.receiver.nil?
      end
    end
  end
end
