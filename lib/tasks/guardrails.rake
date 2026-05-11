# frozen_string_literal: true

namespace :guardrails do
  desc "Initialize Guardrails configuration and analyze stylesheet stack (FORCE=1 to overwrite existing config)"
  task :init do
    require "guardrails/init"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    force = %w[1 true yes].include?(ENV["FORCE"]&.downcase)
    Guardrails::Init.new(root: root, force: force).run
  end

  desc "Audit views and components for UI drift (SUGGEST=1, APPLY=1, FORMAT=json)"
  task :audit do
    require "guardrails/audit"
    require "guardrails/stimulus_audit"
    require "guardrails/partial_similarity"
    require "guardrails/view_component_audit"
    require "guardrails/a11y_audit"
    require "guardrails/cross_codebase_patterns"
    require "guardrails/class_itis"
    require "stringio"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    suggest = %w[1 true yes].include?(ENV["SUGGEST"]&.downcase)
    apply = %w[1 true yes].include?(ENV["APPLY"]&.downcase)
    format = ENV["FORMAT"]&.downcase == "json" ? :json : :text
    similarity_opts = { root: root }
    similarity_opts[:threshold] = ENV["SIMILARITY_THRESHOLD"].to_f if ENV["SIMILARITY_THRESHOLD"]
    pattern_opts = { root: root }
    pattern_opts[:min_size] = ENV["PATTERN_MIN_SIZE"].to_i if ENV["PATTERN_MIN_SIZE"]
    pattern_opts[:min_occurrences] = ENV["PATTERN_MIN_OCCURRENCES"].to_i if ENV["PATTERN_MIN_OCCURRENCES"]
    classitis_opts = { root: root }
    classitis_opts[:min_classes] = ENV["CLASSITIS_MIN_CLASSES"].to_i if ENV["CLASSITIS_MIN_CLASSES"]
    classitis_opts[:min_occurrences] = ENV["CLASSITIS_MIN_OCCURRENCES"].to_i if ENV["CLASSITIS_MIN_OCCURRENCES"]

    if format == :json
      # Run sub-audits silently so the only thing printed to stdout is one
      # JSON document. Audit's own JSON output goes through @output, so we
      # capture it instead of re-emitting.
      sink = StringIO.new
      violations = Guardrails::Audit.new(
        root: root, output: sink, suggest: suggest, apply: apply, format: :text
      ).run
      stimulus = Guardrails::StimulusAudit.new(root: root, output: sink).run
      similarity_opts[:output] = sink
      similarity = Guardrails::PartialSimilarity.new(**similarity_opts).run
      vc = Guardrails::ViewComponentAudit.new(root: root, output: sink).run
      a11y = Guardrails::A11yAudit.new(root: root, output: sink).run
      pattern_opts[:output] = sink
      patterns = Guardrails::CrossCodebasePatterns.new(**pattern_opts).run
      classitis_opts[:output] = sink
      classitis = Guardrails::ClassItis.new(**classitis_opts).run

      require "json"
      payload = {
        summary: {
          violations: violations.length,
          stimulus_orphaned: stimulus.orphaned.length,
          stimulus_dead: stimulus.dead.length,
          similar_partials: similarity.length,
          missing_previews: vc.missing_previews.length,
          orphan_slots: vc.orphan_slots.length,
          a11y: a11y.length,
          patterns: patterns.length,
          classitis: classitis.length
        },
        violations: violations.map(&:to_h),
        stimulus: { orphaned: stimulus.orphaned, dead: stimulus.dead },
        similar_partials: similarity.map(&:to_h),
        view_components: {
          missing_previews: vc.missing_previews,
          orphan_slots: vc.orphan_slots.map(&:to_h)
        },
        a11y: a11y.map(&:to_h),
        patterns: patterns.map { |p|
          { fingerprint: p.fingerprint, shape: p.shape, size: p.size, count: p.count, occurrences: p.occurrences.map(&:to_h) }
        },
        classitis: classitis.map { |c|
          { tag: c.tag, classes: c.classes, count: c.count, occurrences: c.occurrences.map(&:to_h) }
        }
      }
      $stdout.puts JSON.pretty_generate(payload)
    else
      violations = Guardrails::Audit.new(
        root: root, suggest: suggest, apply: apply, format: :text
      ).run
      stimulus = Guardrails::StimulusAudit.new(root: root).run
      similarity = Guardrails::PartialSimilarity.new(**similarity_opts).run
      vc = Guardrails::ViewComponentAudit.new(root: root).run
      a11y = Guardrails::A11yAudit.new(root: root).run
      patterns = Guardrails::CrossCodebasePatterns.new(**pattern_opts).run
      classitis = Guardrails::ClassItis.new(**classitis_opts).run
    end

    exit 1 if violations.any? || stimulus.violations? || similarity.any? || vc.violations? || a11y.any?
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
