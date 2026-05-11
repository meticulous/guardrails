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
    require "guardrails/a11y_deep"
    require "guardrails/visual_diff"
    require "stringio"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    axe_json_path = ENV["AXE_JSON"]

    # Visual-diff is opt-in (baselines need deliberate setup). Enabled
    # when either VISUAL_DIFF=1 is set in the env (sidecar mode) or
    # Guardrails.configuration.visual_diff.enabled was flipped on by a
    # Rails initializer (embedded mode). Env overrides Configuration.
    visual_diff_env = %w[1 true yes].include?(ENV["VISUAL_DIFF"]&.downcase)
    visual_diff_on = visual_diff_env || Guardrails.configuration.visual_diff.enabled
    # Strip + reject blank env values — an empty VISUAL_DIFF_DIR would
    # otherwise be applied as snap_diff_dir = "" and glob from the repo
    # root (potentially scanning the whole tree).
    if (dir = ENV["VISUAL_DIFF_DIR"]) && !dir.strip.empty?
      Guardrails.configure { |c| c.visual_diff.snap_diff_dir = dir.strip }
    end
    if (thr = ENV["VISUAL_DIFF_THRESHOLD"]) && !thr.strip.empty?
      Guardrails.configure { |c| c.visual_diff.threshold = thr.strip }
    end
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
      a11y_deep_runner = axe_json_path ? Guardrails::A11yDeep.new(input: axe_json_path, output: sink) : nil
      a11y_deep = a11y_deep_runner&.run || []
      visual_diff_runner = visual_diff_on ? Guardrails::VisualDiff.new(root: root, output: sink) : nil
      visual_diff = visual_diff_runner&.run || []

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
          a11y_deep: a11y_deep.length,
          patterns: patterns.length,
          classitis: classitis.length,
          visual_diff: visual_diff.length
        },
        violations: violations.map(&:to_h),
        stimulus: { orphaned: stimulus.orphaned, dead: stimulus.dead },
        similar_partials: similarity.map(&:to_h),
        view_components: {
          missing_previews: vc.missing_previews,
          orphan_slots: vc.orphan_slots.map(&:to_h)
        },
        a11y: a11y.map(&:to_h),
        a11y_deep: a11y_deep.map(&:to_h),
        patterns: patterns.map { |p|
          { fingerprint: p.fingerprint, shape: p.shape, size: p.size, count: p.count, occurrences: p.occurrences.map(&:to_h) }
        },
        classitis: classitis.map { |c|
          { tag: c.tag, classes: c.classes, count: c.count, occurrences: c.occurrences.map(&:to_h) }
        },
        visual_diff: visual_diff.map(&:to_h)
      }
      $stdout.puts JSON.pretty_generate(payload)
    else
      # Run each sub-audit against an in-memory sink first so we can
      # render the top-of-report summary before the per-category
      # details (the summary needs every detector's count). Then
      # write the sink + per-category sections out together.
      require "guardrails/report/summary"
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
      a11y_deep_runner = axe_json_path ? Guardrails::A11yDeep.new(input: axe_json_path, output: sink) : nil
      a11y_deep = a11y_deep_runner&.run || []
      visual_diff_runner = visual_diff_on ? Guardrails::VisualDiff.new(root: root, output: sink) : nil
      visual_diff = visual_diff_runner&.run || []

      summary_entries = [
        Guardrails::Report::Summary::Entry.new(
          category: "raw_color", count: violations.count { |v| v.type == :raw_color },
          severity: :error, auto_fix: true
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "tailwind_arbitrary", count: violations.count { |v| v.type == :tailwind_arbitrary },
          severity: :error, auto_fix: true
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "inline_style", count: violations.count { |v| v.type == :inline_style },
          severity: :warning
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "helper_recommended", count: violations.count { |v| v.type == :helper_recommended },
          severity: :warning
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "a11y (static)", count: a11y.length, severity: :error
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "a11y (deep)", count: a11y_deep.length, severity: :error
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "stimulus orphaned", count: stimulus.orphaned.length, severity: :warning
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "stimulus dead", count: stimulus.dead.length, severity: :warning
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "missing previews", count: vc.missing_previews.length, severity: :warning
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "orphan slots", count: vc.orphan_slots.length, severity: :warning
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "visual diff", count: visual_diff.length, severity: :error
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "similar partials", count: similarity.length, severity: :suggestion,
          unit: "pairs", action: "consider deduplicating"
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "cross-codebase patterns", count: patterns.length, severity: :suggestion,
          unit: "candidates", action: "consider extracting partials"
        ),
        Guardrails::Report::Summary::Entry.new(
          category: "class-itis", count: classitis.length, severity: :suggestion,
          unit: "clusters", action: "consider extracting component / @apply"
        )
      ]

      Guardrails::Report::Summary.new(entries: summary_entries, output: $stdout).render
      $stdout.write sink.string
    end

    # Deep a11y findings only fail the audit when their impact crosses
    # the configured threshold (default: any impact fails, same as
    # static a11y). When AXE_JSON is not set, a11y_deep is [] and the
    # check is a no-op. Same logic for visual_diff: opt-in via
    # VISUAL_DIFF=1 / Configuration; threshold gates failure.
    a11y_deep_failing = a11y_deep_runner&.any_failing?(a11y_deep) || false
    visual_diff_failing = visual_diff_runner&.any_failing?(visual_diff) || false
    exit 1 if violations.any? || stimulus.violations? || similarity.any? || vc.violations? || a11y.any? || a11y_deep_failing || visual_diff_failing
  end

  desc "Parse axe-core JSON output and report deep a11y findings (AXE_JSON=path/to/axe.json)"
  task :"a11y:deep" do
    require "guardrails/a11y_deep"
    path = ENV["AXE_JSON"] or abort "Set AXE_JSON=path/to/axe.json (output from `npx @axe-core/cli ... --save`)"
    runner = Guardrails::A11yDeep.new(input: path)
    findings = runner.run
    exit 1 if runner.any_failing?(findings)
  end

  desc "Consume screenshot-diff output and report visual regressions (VISUAL_DIFF_DIR=..., VISUAL_DIFF_THRESHOLD=0.0)"
  task :"visual:deep" do
    require "guardrails/visual_diff"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    # The standalone task implies the user is opting in regardless of
    # Configuration; flip enabled on so a no-config sidecar run works.
    Guardrails.configure { |c| c.visual_diff.enabled = true }
    # Same blank-env guard as the main audit task — see note there.
    if (dir = ENV["VISUAL_DIFF_DIR"]) && !dir.strip.empty?
      Guardrails.configure { |c| c.visual_diff.snap_diff_dir = dir.strip }
    end
    if (thr = ENV["VISUAL_DIFF_THRESHOLD"]) && !thr.strip.empty?
      Guardrails.configure { |c| c.visual_diff.threshold = thr.strip }
    end
    runner = Guardrails::VisualDiff.new(root: root)
    findings = runner.run
    exit 1 if runner.any_failing?(findings)
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
