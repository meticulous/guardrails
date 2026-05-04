# frozen_string_literal: true

namespace :guardrails do
  desc "Initialize Guardrails configuration and analyze stylesheet stack"
  task :init do
    require "guardrails/init"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    Guardrails::Init.new(root: root).run
  end

  desc "Audit views and components for UI drift (set SUGGEST=1 to write a suggestions markdown)"
  task :audit do
    require "guardrails/audit"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    suggest = %w[1 true yes].include?(ENV["SUGGEST"]&.downcase)
    violations = Guardrails::Audit.new(root: root, suggest: suggest).run
    exit 1 if violations.any?
  end

  desc "Generate SVG icon sprite and audit icon usage"
  task :icons do
    puts "guardrails:icons — not yet implemented"
  end

  desc "Audit design tokens and report violations"
  task :tokens do
    puts "guardrails:tokens — not yet implemented"
  end
end
