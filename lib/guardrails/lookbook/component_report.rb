# frozen_string_literal: true

require "pathname"
require "stringio"

module Guardrails
  module Lookbook
    # Generates a per-component findings report meant to be rendered inside
    # a Lookbook panel. Returns a Hash so the consumer can choose how to
    # render it (HTML partial, JSON, etc).
    class ComponentReport
      def initialize(root:)
        @root = Pathname(root)
      end

      # @param component_class_name [String] e.g. "ButtonComponent" or
      #   "Admin::Users::ProfileComponent"
      # @return [Hash, nil] nil when the component class can't be located
      def for(component_class_name)
        class_path = component_class_path(component_class_name)
        return nil unless class_path&.exist?

        template_path = class_path.sub_ext(".html.erb")
        class_relative = relative(class_path)
        template_relative = template_path.exist? ? relative(template_path) : nil

        {
          component: component_class_name,
          class_file: class_relative,
          template_file: template_relative,
          violations: violations_for(template_relative),
          orphan_slots: orphan_slots_for(class_relative),
          similar_templates: similar_templates_for(template_relative)
        }
      end

      private

      def component_class_path(class_name)
        relative = class_name.to_s
                             .gsub("::", "/")
                             .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                             .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                             .downcase
        @root.join("app/components", "#{relative}.rb")
      end

      def relative(path)
        path.relative_path_from(@root).to_s
      end

      def violations_for(template_relative)
        return [] if template_relative.nil?

        require_relative "../audit"
        Guardrails::Audit.new(root: @root, output: StringIO.new).run
          .select { |v| v.file == template_relative }
          .map(&:to_h)
      end

      def orphan_slots_for(class_relative)
        require_relative "../view_component_audit"
        Guardrails::ViewComponentAudit.new(root: @root, output: StringIO.new).run.orphan_slots
          .select { |o| o.file == class_relative }
          .map(&:to_h)
      end

      def similar_templates_for(template_relative)
        return [] if template_relative.nil?

        require_relative "../partial_similarity"
        Guardrails::PartialSimilarity.new(root: @root, output: StringIO.new).run
          .select { |f| f.file_a == template_relative || f.file_b == template_relative }
          .map { |f| { partner: (f.file_a == template_relative ? f.file_b : f.file_a), score: f.score } }
      end
    end
  end
end
