# frozen_string_literal: true

require_relative "guardrails/version"
require_relative "guardrails/railtie" if defined?(Rails::Railtie)

module Guardrails
  class Error < StandardError; end
end
