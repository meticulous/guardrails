# frozen_string_literal: true

require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true

  # No caching for the demo — keep page rendering predictable.
  config.action_controller.perform_caching = false
  config.cache_store = :memory_store

  config.public_file_server.enabled = true
  config.public_file_server.headers = { "Cache-Control" => "public, max-age=0" }

  config.action_dispatch.show_exceptions = :all
  config.action_controller.raise_on_missing_callback_actions = true

  # Don't serve assets with a digest in dev — easier to point at icons
  # from views without a Sprockets-style asset helper.
  config.assets.compile = true if config.respond_to?(:assets)

  config.logger = ActiveSupport::Logger.new($stdout)
  config.logger.formatter = Logger::Formatter.new
end
