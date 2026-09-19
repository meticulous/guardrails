# frozen_string_literal: true

require "stringio"
require "pathname"
require_relative "../audit"
require_relative "../stimulus_audit"
require_relative "../partial_similarity"
require_relative "../view_component_audit"
require_relative "../a11y_audit"
require_relative "../cross_codebase_patterns"
require_relative "../class_itis"
require_relative "../a11y_deep"
require_relative "../visual_diff"
require_relative "summary"
require_relative "finding"
require_relative "severity"
require_relative "../configuration"

module Guardrails
  module Report
    # One full audit pass: runs every detector once and holds the
    # results so any number of front-ends (text report, JSON, and
    # anything interactive) can render from the same data without
    # re-running detectors or re-deriving the summary.
    #
    # Detectors still print their own per-section text; Run captures
    # that into `body` rather than letting it hit the terminal, because
    # the summary has to print first and needs every detector's count.
    #
    # `new` takes plain arguments so it's callable from specs and
    # non-rake entry points; `from_env` is the one place the audit's
    # env-var surface is parsed, shared by every task that runs one.
    class Run
      TRUTHY = %w[1 true yes].freeze

      attr_reader :violations, :stimulus, :similarity, :view_components,
                  :a11y, :patterns, :classitis, :a11y_deep, :visual_diff, :min_severity

      # Builds a Run from the documented env vars (SUGGEST, APPLY,
      # AXE_JSON, VISUAL_DIFF*, SIMILARITY_THRESHOLD, PATTERN_*,
      # CLASSITIS_*, SEVERITY). Raises ArgumentError on a SEVERITY it
      # doesn't recognize — a typo there would otherwise silently
      # un-gate a CI check.
      def self.from_env(root:, style: nil, env: ENV)
        # Visual-diff is opt-in (baselines need deliberate setup). Enabled
        # when either VISUAL_DIFF=1 is set in the env (sidecar mode) or
        # Guardrails.configuration.visual_diff.enabled was flipped on by a
        # Rails initializer (embedded mode). Env overrides Configuration.
        visual_diff_on = truthy?(env["VISUAL_DIFF"]) || Guardrails.configuration.visual_diff.enabled
        # Strip + reject blank env values — an empty VISUAL_DIFF_DIR would
        # otherwise be applied as snap_diff_dir = "" and glob from the repo
        # root (potentially scanning the whole tree).
        if (dir = env["VISUAL_DIFF_DIR"]) && !dir.strip.empty?
          Guardrails.configure { |c| c.visual_diff.snap_diff_dir = dir.strip }
        end
        if (thr = env["VISUAL_DIFF_THRESHOLD"]) && !thr.strip.empty?
          Guardrails.configure { |c| c.visual_diff.threshold = thr.strip }
        end

        similarity = {}
        similarity[:threshold] = env["SIMILARITY_THRESHOLD"].to_f if env["SIMILARITY_THRESHOLD"]
        patterns = {}
        patterns[:min_size] = env["PATTERN_MIN_SIZE"].to_i if env["PATTERN_MIN_SIZE"]
        patterns[:min_occurrences] = env["PATTERN_MIN_OCCURRENCES"].to_i if env["PATTERN_MIN_OCCURRENCES"]
        classitis = {}
        classitis[:min_classes] = env["CLASSITIS_MIN_CLASSES"].to_i if env["CLASSITIS_MIN_CLASSES"]
        classitis[:min_occurrences] = env["CLASSITIS_MIN_OCCURRENCES"].to_i if env["CLASSITIS_MIN_OCCURRENCES"]

        new(root: root, style: style,
            suggest: truthy?(env["SUGGEST"]), apply: truthy?(env["APPLY"]),
            axe_json: env["AXE_JSON"], visual_diff: visual_diff_on,
            similarity: similarity, patterns: patterns, classitis: classitis,
            min_severity: Severity.parse(env["SEVERITY"]))
      end

      def self.truthy?(value)
        TRUTHY.include?(value&.downcase)
      end

      # `style` should be bound to the *real* output stream, not the
      # capture sink: detectors write into a StringIO but must make
      # ANSI decisions against the terminal, or the report body prints
      # plain while the summary around it is colored. Pass nil to get
      # uncolored output (what JSON mode wants — the body is discarded).
      def initialize(root:, style: nil, suggest: false, apply: false,
                     axe_json: nil, visual_diff: false,
                     similarity: {}, patterns: {}, classitis: {},
                     min_severity: Severity::DEFAULT)
        @min_severity = min_severity
        @root = Pathname(root)
        @style = style
        @suggest = suggest
        @apply = apply
        @axe_json = axe_json
        @visual_diff_on = visual_diff
        @similarity_opts = similarity
        @pattern_opts = patterns
        @classitis_opts = classitis
        @sink = StringIO.new
      end

      def call
        # Detectors whose findings all sit below the severity floor
        # aren't run at all — SEVERITY=error skips the two slowest
        # (similarity, patterns) rather than computing results to
        # discard. Audit and A11yDeep emit mixed severities, so they
        # always run and filter internally.
        @violations = detect(Audit.new(**common, suggest: @suggest, apply: @apply, format: :text,
                                                 min_severity: @min_severity))
        @stimulus = wanted?(:warning) ? detect(StimulusAudit.new(**common)) : StimulusAudit::Result.new(orphaned: [], dead: [])
        @similarity = wanted?(:suggestion) ? detect(PartialSimilarity.new(**common, **@similarity_opts)) : []
        @view_components = if wanted?(:warning) then detect(ViewComponentAudit.new(**common))
                           else ViewComponentAudit::Result.new(missing_previews: [], orphan_slots: [])
                           end
        @a11y = detect(A11yAudit.new(**common))
        @patterns = wanted?(:suggestion) ? detect(CrossCodebasePatterns.new(**common, **@pattern_opts)) : []
        @classitis = wanted?(:suggestion) ? detect(ClassItis.new(**common, **@classitis_opts)) : []
        @a11y_deep_runner = if @axe_json
                              A11yDeep.new(input: @axe_json, output: @sink, style: @style, min_severity: @min_severity)
                            end
        @a11y_deep = @a11y_deep_runner ? detect(@a11y_deep_runner) : []
        @visual_diff_runner = @visual_diff_on ? VisualDiff.new(**common) : nil
        @visual_diff = @visual_diff_runner ? detect(@visual_diff_runner) : []
        self
      end

      # Severities this run didn't look at (empty by default).
      def muted_severities
        Severity.muted(@min_severity)
      end

      # Every finding as detector-agnostic data (see Report::Finding),
      # grouped by category and ordered errors → warnings →
      # suggestions, biggest category first — the same order the
      # summary rollup uses. Category names match `summary_entries`.
      def categories
        @categories ||= @detected
                        .flat_map { |detector, result| detector.categories(result) }
                        .sort_by
                        .with_index { |c, i| [Summary::SEVERITY_ORDER.index(c.severity), -c.count, i] }
      end

      def findings
        categories.flat_map(&:findings)
      end

      # The per-detector sections, exactly as the detectors printed them.
      def body
        @sink.string
      end

      def summary_entries
        [
          entry("raw_color", count_type(:raw_color), :error, auto_fix: true),
          entry("tailwind_arbitrary", count_type(:tailwind_arbitrary), :error, auto_fix: true),
          entry("inline_style", count_type(:inline_style), :warning),
          entry("helper_recommended", count_type(:helper_recommended), :warning),
          entry("a11y (static)", a11y.length, :error),
          entry("a11y (deep)", a11y_deep.length, :error),
          entry("stimulus orphaned", stimulus.orphaned.length, :warning),
          entry("stimulus dead", stimulus.dead.length, :warning),
          entry("missing previews", view_components.missing_previews.length, :warning),
          entry("orphan slots", view_components.orphan_slots.length, :warning),
          entry("visual diff", visual_diff.length, :error),
          entry("similar partials", similarity.length, :suggestion,
                unit: "pairs", action: "consider deduplicating"),
          entry("cross-codebase patterns", patterns.length, :suggestion,
                unit: "candidates", action: "consider extracting partials"),
          entry("class-itis", classitis.length, :suggestion,
                unit: "clusters", action: "consider extracting component / @apply")
        ]
      end

      # FORMAT=json payload. Shape is a public contract — unchanged
      # since 1.0.0.
      def to_h
        {
          summary: {
            violations: violations.length,
            stimulus_orphaned: stimulus.orphaned.length,
            stimulus_dead: stimulus.dead.length,
            similar_partials: similarity.length,
            missing_previews: view_components.missing_previews.length,
            orphan_slots: view_components.orphan_slots.length,
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
            missing_previews: view_components.missing_previews,
            orphan_slots: view_components.orphan_slots.map(&:to_h)
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
      end

      # Exit-code contract: any error or warning fails; the suggestion-
      # tier pattern / class-itis detectors don't. Deep a11y and visual
      # diff only fail when a finding crosses their configured
      # threshold, and are no-ops when not opted into.
      def failing?
        violations.any? || stimulus.violations? || similarity.any? ||
          view_components.violations? || a11y.any? ||
          (@a11y_deep_runner&.any_failing?(a11y_deep) || false) ||
          (@visual_diff_runner&.any_failing?(visual_diff) || false)
      end

      private

      # Runs a detector and remembers the pair, so `categories` can ask
      # each detector to normalize its own result later — only
      # front-ends that want findings-as-data pay for building them.
      def detect(detector)
        result = detector.run
        (@detected ||= []) << [detector, result]
        result
      end

      def wanted?(severity)
        Severity.include?(severity, @min_severity)
      end

      def common
        { root: @root, output: @sink, style: @style }
      end

      def count_type(type)
        violations.count { |v| v.type == type }
      end

      def entry(category, count, severity, **rest)
        Summary::Entry.new(category: category, count: count, severity: severity, **rest)
      end
    end
  end
end
