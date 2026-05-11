# frozen_string_literal: true

require_relative "component_report"

module Guardrails
  module Lookbook
    # Registers a `:guardrails` Lookbook panel that renders ComponentReport
    # findings inline next to each preview. The Railtie calls `register!`
    # at app boot when `defined?(::Lookbook)`, so users no longer need to
    # wire the panel by hand.
    #
    # Extracted from the Railtie so the registration logic and the
    # locals lambda are unit-testable without booting Rails — pass a
    # stub `lookbook` and the assertions can inspect what got registered.
    module PanelRegistration
      module_function

      # The gem ships the panel partial inside `lib/guardrails/lookbook/views/`.
      # Adding that dir to ActionView's view paths means the standard Rails
      # partial-resolution machinery finds `lookbook_panels/_guardrails.html.erb`
      # without users having to copy it into their app.
      VIEW_PATH = File.expand_path("views", __dir__)

      def register!(lookbook: ::Lookbook, view_consumer: nil)
        append_view_path(view_consumer)
        register_panel(lookbook)
      end

      # APPEND, not prepend — the host's `app/views` must keep precedence
      # so that `app/views/lookbook_panels/_guardrails.html.erb` in the
      # host wins over the gem's bundled default. Prepending would flip
      # that and silently break the documented override mechanism.
      def append_view_path(view_consumer = nil)
        target = view_consumer || (defined?(::ActionController::Base) ? ::ActionController::Base : nil)
        return unless target&.respond_to?(:append_view_path)

        target.append_view_path(VIEW_PATH)
      end

      # Lookbook 2.x exposes `Lookbook.add_panel(name, partial_path, opts)`
      # at the module level. opts[:locals] can be a callable that receives
      # the inspector_data Store at render time and returns a Hash of
      # locals for the partial. The pre-2.x API of
      # `config.lookbook.preview_inspector.panels.add` doesn't exist.
      def register_panel(lookbook = ::Lookbook)
        return unless lookbook.respond_to?(:add_panel)

        lookbook.add_panel(:guardrails, "lookbook_panels/guardrails", {
          label: "Guardrails",
          locals: ->(data) { { findings: report_for_preview(data) } }
        })
      end

      def report_for_preview(data)
        preview_class_name = preview_class_name_from(data)
        return nil unless preview_class_name

        component_class_name = component_class_name_from(preview_class_name)
        return nil unless component_class_name

        ComponentReport.new(root: ::Rails.root).for(component_class_name)
      end

      # Lookbook's inspector_data exposes the current preview's class via
      # data.preview.preview_class_name (2.x) or data.preview.preview_class.name
      # (older). Probe defensively rather than hardcoding one path.
      def preview_class_name_from(data)
        return nil if data.nil?

        if data.respond_to?(:preview) && data.preview
          preview = data.preview
          return preview.preview_class_name if preview.respond_to?(:preview_class_name)
          return preview.preview_class.name if preview.respond_to?(:preview_class)
        end
        return data.preview_class.name if data.respond_to?(:preview_class)

        nil
      end

      # The preview class for a ViewComponent is conventionally
      # `<Component>Preview` — Lookbook itself relies on this in
      # `PreviewEntity#guess_render_targets`. Strip the suffix to get
      # the component class name ComponentReport expects. If there's
      # no `Preview` suffix we can't infer the target component, so
      # we punt rather than guess.
      def component_class_name_from(preview_class_name)
        return nil unless preview_class_name.to_s.end_with?("Preview")

        preview_class_name.to_s.chomp("Preview")
      end
    end
  end
end
