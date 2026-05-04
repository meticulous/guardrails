# frozen_string_literal: true

namespace :guardrails do
  desc "Initialize Guardrails configuration and analyze stylesheet stack"
  task :init do
    require "guardrails/init"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    Guardrails::Init.new(root: root).run
  end

  desc "Audit views and components for UI drift (SUGGEST=1 writes markdown; FORMAT=json for machine-readable output)"
  task :audit do
    require "guardrails/audit"
    require "guardrails/stimulus_audit"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    suggest = %w[1 true yes].include?(ENV["SUGGEST"]&.downcase)
    format = ENV["FORMAT"]&.downcase == "json" ? :json : :text
    violations = Guardrails::Audit.new(root: root, suggest: suggest, format: format).run
    stimulus = Guardrails::StimulusAudit.new(root: root).run
    exit 1 if violations.any? || stimulus.violations?
  end

  desc "Generate SVG icon sprite and audit icon usage"
  task :icons do
    require "guardrails/icons"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    Guardrails::Icons.new(root: root).run
  end

  desc "Audit design tokens and report drift"
  task :tokens do
    require "guardrails/tokens"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    Guardrails::Tokens.new(root: root).run
  end
end
