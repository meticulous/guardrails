# frozen_string_literal: true

require "pathname"
require_relative "configuration"
require_relative "report/style"

module Guardrails
  # Consumes screenshot-diff tool output and folds findings into the
  # unified audit report. Same playbook as `A11yDeep` for axe — parser
  # only, no Capybara / Chromium / Playwright runtime deps. Users keep
  # their existing visual-regression toolchain; Guardrails provides the
  # merge + report + exit-code contract.
  #
  # Adapter selection comes from `Guardrails.configuration.visual_diff.adapter`
  # (default `:snap_diff`, the Rails-native baselines-in-git workflow).
  # BackstopJS support tracked in issue #15.
  class VisualDiff
    # Normalized across every adapter. Fields adapter-specific shapes
    # don't supply are nil — consumers should not assume presence.
    #
    # Defined before the adapter requires so the constant exists by the
    # time `lib/guardrails/visual_diff/snap_diff.rb` loads.
    Finding = Struct.new(
      :scenario,        # human label, e.g. "checkout/cart" or "homepage_desktop"
      :viewport,        # "desktop" / "mobile" / nil if not applicable
      :mismatch_ratio,  # 0.0..1.0 when the adapter emits one; nil for boolean adapters (snap_diff)
      :baseline_path,   # relative path to the reference image
      :current_path,    # relative path to the actual screenshot
      :diff_path,       # relative path to the diff image, nil when no diff exists
      :url,             # optional — set by adapters whose scenarios carry URLs (BackstopJS)
      :selector,        # optional — same
      keyword_init: true
    ) do
      def to_h
        super
      end
    end

    def initialize(root:, output: $stdout,
                   adapter: nil, threshold: nil, style: nil)
      @root = Pathname(root)
      @output = output
      cfg = Guardrails.configuration.visual_diff
      # Coerce constructor inputs the same way Configuration setters
      # do, so `VisualDiff.new(adapter: "snap_diff", threshold: "0.1")`
      # works the same as `Guardrails.configure { |c| c.visual_diff.
      # adapter = "snap_diff"; c.visual_diff.threshold = "0.1" }`.
      @adapter_name = coerce_adapter(adapter) || cfg.adapter
      @threshold = threshold.nil? ? cfg.threshold : Float(threshold)
      @style = style || Report::Style.new(io: output)
    end

    def run
      findings = collect
      print_report(findings)
      findings
    end

    # Returns true when any finding's mismatch_ratio exceeds the
    # threshold. Adapters that don't emit a ratio (snap_diff: presence
    # of a .diff.png is binary) report nil, which we treat as
    # "unconditional fail" — those findings always fail.
    def any_failing?(findings)
      findings.any? { |f| failing?(f) }
    end

    def collect
      adapter.collect
    end

    private

    def adapter
      case @adapter_name
      when :snap_diff
        SnapDiff.new(
          root: @root,
          dir: Guardrails.configuration.visual_diff.snap_diff_dir
        )
      else
        raise ArgumentError, "Unknown visual_diff adapter: #{@adapter_name.inspect}"
      end
    end

    def coerce_adapter(value)
      return nil if value.nil?

      value.to_sym
    end

    def failing?(finding)
      ratio = finding.mismatch_ratio
      return true if ratio.nil?

      ratio > @threshold
    end

    def print_report(findings)
      return if findings.empty?

      noun = findings.length == 1 ? "finding" : "findings"
      @output.puts ""
      @output.puts @style.section_heading(
        :error,
        "visual diff (#{findings.length} #{noun}, adapter: #{@adapter_name}, threshold: #{@threshold})"
      )
      @output.puts "  Screenshot-diff tool flagged these scenarios. Review each diff image"
      @output.puts "  and either accept the new baseline (commit the updated screenshot) or"
      @output.puts "  fix the regression that caused the visual change."

      findings.each do |f|
        ratio_label = f.mismatch_ratio.nil? ? "[diff present]" : "[#{(f.mismatch_ratio * 100).round(2)}% mismatch]"
        suffix = f.viewport ? " (#{f.viewport})" : ""

        @output.puts ""
        @output.puts "  #{@style.severity(:error, "#{ratio_label} #{f.scenario}#{suffix}")}"
        @output.puts "    #{@style.suggestion("compare baseline ↔ diff; accept the new baseline or fix the regression")}"
        @output.puts "    #{@style.location("baseline: #{f.baseline_path}")}" if f.baseline_path
        @output.puts "    #{@style.location("diff:     #{f.diff_path}")}" if f.diff_path
        @output.puts "    #{@style.location("url:      #{f.url}")}" if f.url
        @output.puts "    #{@style.location("selector: #{f.selector}")}" if f.selector
      end
    end
  end
end

require_relative "visual_diff/snap_diff"
