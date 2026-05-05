# frozen_string_literal: true

require_relative "lib/guardrails/version"

Gem::Specification.new do |spec|
  spec.name = "guardrails"
  spec.version = Guardrails::VERSION
  spec.authors = ["John Athayde"]
  spec.email = ["jmpa@meticulous.com"]

  spec.summary = "Rails toolset for preventing UI drift in AI-assisted applications."
  spec.description = "Opinionated auditing and enforcement for design-system consistency: " \
                     "component inventory, icon sprites, type scale, and color token management."
  spec.homepage = "https://github.com/meticulous/guardrails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "doc/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.1"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
end
