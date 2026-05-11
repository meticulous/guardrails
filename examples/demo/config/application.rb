# frozen_string_literal: true

require_relative "boot"

# Pull in the minimum slice of Rails the demo actually needs. Skipping
# ActiveRecord / ActiveStorage / ActionCable / ActionMailbox /
# ActiveJob keeps the boot tiny — the demo doesn't persist anything,
# doesn't background-process, doesn't email. The audits are entirely
# file-driven, so we only need view rendering + asset serving.
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "propshaft"

Bundler.require(*Rails.groups)

module GuardrailsDemo
  class Application < Rails::Application
    config.load_defaults 7.2

    config.api_only = false

    # `examples/demo` is the Rails root; tighten autoload to match.
    config.autoload_lib(ignore: %w[])

    # Don't try to provision a database — there isn't one.
    config.active_record_belongs_to_required_by_default = false if defined?(ActiveRecord)

    # Quiet down generators we'll never run.
    config.generators do |g|
      g.test_framework nil
      g.system_tests   nil
    end
  end
end
