# frozen_string_literal: true

require_relative "component_report"

module Guardrails
  module Lookbook
    # Registers a `:guardrails` Lookbook panel that renders ComponentReport
    # findings inline next to each preview. The Railtie calls `register!`
    # at app boot when `defined?(::Lookbook)`, so users no longer need to
    # wire the panel by hand.
    #
    # Extracted from the Railtie so the registration logic is unit-testable
    # without booting Rails — pass a stub `config` and the assertions can
    # inspect what the panel block does.
    module PanelRegistration
      module_function

      # The gem ships the panel partial inside `lib/guardrails/lookbook/views/`.
      # Adding that dir to ActionView's view paths means the standard Rails
      # partial-resolution machinery finds `lookbook_panels/_guardrails.html.erb`
      # without users having to copy it into their app.
      VIEW_PATH = File.expand_path("views", __dir__)

      def register!(config: ::Rails.application.config, view_consumer: nil)
        append_view_path(view_consumer)
        register_panel(config)
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

      # Adds the `:guardrails` panel to Lookbook's preview inspector. The
      # panel's locals lambda is evaluated per-render: it resolves the
      # current preview's component class name and runs ComponentReport
      # against it. `findings` is `nil` when the component class can't be
      # located (the partial handles that gracefully).
      def register_panel(config)
        return unless config.respond_to?(:lookbook)

        panels = config.lookbook.preview_inspector.panels
        panels.add(:guardrails) do |panel|
          panel.label = "Guardrails"
          panel.partial = "lookbook_panels/guardrails"
          panel.locals = ->(data) { { findings: report_for_preview(data) } }
        end
      end

      def report_for_preview(data)
        preview_class_name = preview_class_name_from(data)
        return nil unless preview_class_name

        ComponentReport.new(root: ::Rails.root).for(preview_class_name)
      end

      # Lookbook's panel block hands the locals lambda a data object whose
      # API has shifted across versions. Probe defensively rather than
      # hardcoding one path.
      def preview_class_name_from(data)
        return nil if data.nil?
        if data.respond_to?(:preview) && data.preview.respond_to?(:preview_class)
          data.preview.preview_class.name
        elsif data.respond_to?(:preview_class)
          data.preview_class.name
        end
      end
    end
  end
end
