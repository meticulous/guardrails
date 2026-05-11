# frozen_string_literal: true

require "rails/railtie"

module Guardrails
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/guardrails.rake", __dir__)
    end

    # Auto-register the Lookbook panel when Lookbook is on the load path.
    # Pre-0.5.0 users had to wire the panel by hand in an initializer
    # (see doc/LOOKBOOK.md history); now the gem ships the partial and
    # registers it on boot.
    initializer "guardrails.lookbook_panel" do
      next unless defined?(::Lookbook)

      require_relative "lookbook/panel_registration"
      ::Guardrails::Lookbook::PanelRegistration.register!
    end
  end
end
