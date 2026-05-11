# frozen_string_literal: true

require "active_support/core_ext/integer/time"

# The demo isn't meant to be deployed — this file exists so
# `RAILS_ENV=production rails runner` doesn't choke on a missing
# environment file. Everything stays inert.
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.public_file_server.enabled = true
  config.action_controller.perform_caching = true
  config.cache_store = :memory_store
  config.action_dispatch.show_exceptions = :rescuable
  config.log_level = :info
  config.logger = ActiveSupport::Logger.new($stdout)
end
