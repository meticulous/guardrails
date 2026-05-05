# frozen_string_literal: true

require "rails/railtie"

module Guardrails
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/guardrails.rake", __dir__)
    end
  end
end
