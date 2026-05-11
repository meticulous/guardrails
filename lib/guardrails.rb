# frozen_string_literal: true

require_relative "guardrails/version"
# Configuration carries the `Guardrails.configure { |c| ... }` block
# users place in `config/initializers/guardrails.rb`. Loaded eagerly
# at `require "guardrails"` time so the initializer doesn't NoMethodError
# on first use — caught by the local-build verification of 1.0.0
# before the third publish attempt.
require_relative "guardrails/configuration"
require_relative "guardrails/railtie" if defined?(Rails::Railtie)

module Guardrails
  class Error < StandardError; end
end
