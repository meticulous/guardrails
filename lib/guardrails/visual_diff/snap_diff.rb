# frozen_string_literal: true

require "pathname"

module Guardrails
  class VisualDiff
    # Adapter for snap_diff-capybara (formerly capybara-screenshot-diff).
    # The gem commits baselines to git under `doc/screenshots/` by
    # convention. After a failed run there's a `<name>.diff.png` sibling
    # next to `<name>.png`. Walking the directory tree and pairing names
    # gives us a binary pass/fail per scenario without needing snap_diff
    # to emit a JSON report (see upstream issue — TODO: link once filed).
    #
    # Limits:
    # - No mismatch percentage; snap_diff is binary at the filesystem
    #   level. Findings emit `mismatch_ratio: nil` and VisualDiff treats
    #   nil as "unconditionally failing" (any diff fails).
    # - No URL / viewport / selector — those live in snap_diff's
    #   Capybara tests, not the artifact tree. Adapters that have them
    #   (BackstopJS, issue #15) populate the optional fields.
    class SnapDiff
      DIFF_SUFFIX = ".diff.png"
      HEATMAP_SUFFIX = ".heatmap.diff.png"

      def initialize(root:, dir:)
        @root = Pathname(root)
        @dir = @root.join(dir)
      end

      def collect
        return [] unless @dir.directory?

        diff_files.map { |diff| build_finding(diff) }.compact
      end

      private

      # Find every `<name>.diff.png` under @dir, recursively. Skip
      # `<name>.heatmap.diff.png` files — those are visualization
      # companions, not separate findings.
      def diff_files
        Pathname.glob(@dir.join("**/*#{DIFF_SUFFIX}")).reject do |path|
          path.basename.to_s.end_with?(HEATMAP_SUFFIX)
        end
      end

      def build_finding(diff_path)
        baseline_path = baseline_for(diff_path)
        ::Guardrails::VisualDiff::Finding.new(
          scenario: scenario_name(diff_path),
          viewport: nil,
          mismatch_ratio: nil, # snap_diff is binary at the FS layer
          baseline_path: relative(baseline_path),
          current_path: nil,   # snap_diff doesn't keep a separate "current" image after the test run
          diff_path: relative(diff_path),
          url: nil,
          selector: nil
        )
      end

      # `name.diff.png` → `name.png` (sibling baseline).
      def baseline_for(diff_path)
        stem = diff_path.basename.to_s.sub(/#{Regexp.escape(DIFF_SUFFIX)}\z/, ".png")
        diff_path.dirname.join(stem)
      end

      # Scenario label = path under @dir without the `.diff.png` suffix,
      # so `doc/screenshots/checkout/cart.diff.png` → "checkout/cart".
      def scenario_name(diff_path)
        rel = diff_path.relative_path_from(@dir).to_s
        rel.sub(/#{Regexp.escape(DIFF_SUFFIX)}\z/, "")
      end

      def relative(path)
        return nil if path.nil?

        path.relative_path_from(@root).to_s
      end
    end
  end
end
