# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "stringio"
require "time"
require_relative "../version"
require_relative "../audit"
require_relative "../a11y_audit"
require_relative "../class_itis"
require_relative "../cross_codebase_patterns"
require_relative "../partial_similarity"
require_relative "../tokens"
require_relative "config"

module Guardrails
  module FeedRamp
    # How much UI drift the app has, as one comparable number: issues per
    # 100 templates, from three buckets. Meant for before/after runs (an
    # agent session with and without Feed Ramp, a branch against main),
    # so it always uses the detectors' default thresholds, ignores the
    # audit's env vars, and records what could make two runs differ: the
    # gem version, a digest of guardrails.yml, and the git commit.
    #
    #   - hardcoded_values: raw colours and arbitrary Tailwind values and
    #     inline styles in templates, hex literals in stylesheets
    #   - reinvented_components: markup copying an existing component
    #     (component_match), occurrences of class-itis clusters and
    #     repeated markup, and pairs of near-identical partials
    #   - accessibility: the static a11y rules
    #
    # Templates are the ones `ui_guardrails:audit` scans, so its
    # `scan_paths` and `ignore` settings apply to every bucket.
    #
    # It never fails a build; the audit does that.
    class Score
      SCHEMA_VERSION = 1
      SCORES_DIR = "scores"
      BUCKETS = %w[hardcoded_values reinvented_components accessibility].freeze
      HARDCODED_TYPES = %i[raw_color tailwind_arbitrary inline_style].freeze

      def initialize(root:, config: Config.load(root), clock: -> { Time.now.utc })
        @root = Pathname(root).expand_path
        @config = config
        @clock = clock
      end

      def to_h
        @to_h ||= measure
      end

      def to_json(*)
        "#{JSON.pretty_generate(to_h)}\n"
      end

      def dir
        @root.join(@config.output_dir, SCORES_DIR)
      end

      # Saves to `<output_dir>/scores/<UTC time>.json`, which keeps itself
      # out of git. Returns the path.
      def write
        dir.mkpath
        ignore = dir.join(".gitignore")
        ignore.write("# Written by ui_guardrails: scores are local, compare them with BASELINE=\n*\n") unless ignore.exist?
        path = dir.join("#{Time.iso8601(to_h["generated_at"]).strftime("%Y%m%dT%H%M%SZ")}.json")
        path.write(to_json)
        path
      end

      # The newest saved score, or nil.
      def latest
        dir.glob("*.json").max_by(&:basename)
      end

      # `baseline` and `current` are score hashes. Counts are current
      # minus baseline; `notes` says what makes them hard to compare.
      def self.compare(current, baseline)
        totals = %w[issues per_100_templates].to_h { |key| [key, delta(current.dig("totals", key), baseline.dig("totals", key))] }
        totals["templates_scanned"] = delta(current["templates_scanned"], baseline["templates_scanned"])
        buckets = BUCKETS.to_h do |bucket|
          now = current.dig("buckets", bucket) || {}
          before = baseline.dig("buckets", bucket) || {}
          types = ((now["by_type"] || {}).keys | (before["by_type"] || {}).keys).sort.to_h do |type|
            [type, delta(now.dig("by_type", type).to_i, before.dig("by_type", type).to_i)]
          end
          [bucket, { "count" => delta(now["count"].to_i, before["count"].to_i), "by_type" => types }]
        end
        files = ((current["files"] || {}).keys | (baseline["files"] || {}).keys).filter_map do |file|
          change = (current.dig("files", file, "total") || 0) - (baseline.dig("files", file, "total") || 0)
          [file, change] unless change.zero?
        end
        notes = []
        notes << "guardrails.yml changed" if current["config_digest"] != baseline["config_digest"]
        notes << "scored by #{baseline["generator"]}, now #{current["generator"]}" if current["generator"] != baseline["generator"]
        { "baseline" => baseline.slice("generated_at", "git"), "totals" => totals, "buckets" => buckets,
          "files" => files.sort_by { |file, change| [-change.abs, file] }.to_h, "notes" => notes }
      end

      LABELS = { "hardcoded_values" => "Hardcoded values", "reinvented_components" => "Reinvented components",
                 "accessibility" => "Accessibility" }.freeze

      # The text summary: the headline, one line per bucket, and with a
      # comparison, how each moved and the files that moved most.
      def self.summary(score, comparison = nil)
        totals = score["totals"]
        rate = totals["per_100_templates"]
        headline = rate ? "#{format_number(rate)} issues per 100 templates" : "no templates scanned"
        lines = ["UI drift score: #{headline} (#{plural(totals["issues"], "issue")} in " \
                 "#{plural(score["templates_scanned"], "template")})", ""]
        BUCKETS.each do |bucket|
          data = score.dig("buckets", bucket)
          types = data["by_type"].sort_by { |type, count| [-count, type] }.map { |type, count| "#{type} #{count}" }
          lines << format("  %-23s %5d  %s", LABELS[bucket], data["count"], types.join(", ")).rstrip
        end
        return lines.join("\n") unless comparison

        base = comparison["baseline"]
        against = [base["generated_at"], base.dig("git", "commit")].compact.join(", ")
        issues = comparison.dig("totals", "issues")
        per100 = comparison.dig("totals", "per_100_templates")
        lines << ""
        lines << "Against #{against}: #{issues["before"]} → #{issues["after"]} issues (#{signed(issues["change"])})" \
                 "#{per100["change"] ? ", #{format_number(per100["before"])} → #{format_number(per100["after"])} per 100 templates" : ""}"
        BUCKETS.each do |bucket|
          count = comparison.dig("buckets", bucket, "count")
          lines << format("  %-23s %5d → %d (%s)", LABELS[bucket], count["before"], count["after"], signed(count["change"]))
        end
        moved = comparison["files"].first(5).map { |file, change| "#{file} #{signed(change)}" }
        lines << "  Most changed: #{moved.join(", ")}" if moved.any?
        comparison["notes"].each { |note| lines << "  Note: #{note}, so the runs may not be comparable." }
        lines.join("\n")
      end

      def self.plural(count, word)
        "#{count} #{word}#{"s" unless count == 1}"
      end

      def self.signed(number)
        return "n/a" if number.nil?

        number.positive? ? "+#{format_number(number)}" : format_number(number).sub("-", "−")
      end

      def self.format_number(number)
        number.to_f == number.to_i ? number.to_i.to_s : number.to_s
      end

      def self.delta(now, before)
        change = now && before ? (now - before).round(1) : nil
        change = change.to_i if change && change == change.to_i
        { "before" => before, "after" => now, "change" => change }
      end

      private

      def measure
        templates = audit.templates
        found = { "hardcoded_values" => hardcoded, "reinvented_components" => reinvented, "accessibility" => accessibility }
                .transform_values { |entries| entries.select { |_type, file| counted?(file) } }
        buckets = found.transform_values do |entries|
          by_type = entries.map(&:first).tally.sort.to_h
          { "count" => entries.length, "per_100_templates" => rate(entries.length, templates.length), "by_type" => by_type }
        end
        issues = buckets.sum { |_, bucket| bucket["count"] }
        {
          "schema_version" => SCHEMA_VERSION,
          "generator" => "ui_guardrails #{VERSION}",
          "generated_at" => @clock.call.utc.iso8601,
          "git" => git_state,
          "config_digest" => config_digest,
          "templates_scanned" => templates.length,
          "totals" => { "issues" => issues, "per_100_templates" => rate(issues, templates.length) },
          "buckets" => buckets,
          "files" => by_file(found)
        }
      end

      # Each finding as [type, file or nil].
      def hardcoded
        templates = audit_violations.select { |v| HARDCODED_TYPES.include?(v.type) }.map { |v| [v.type.to_s, v.file] }
        tokens = Tokens.new(root: @root, output: StringIO.new)
        stylesheets = tokens.detect_drift(tokens.parse_tokens).map { |drift| ["stylesheet_color", drift.file] }
        templates + stylesheets
      end

      def reinvented
        class_itis = ClassItis.new(root: @root, output: sink).run
                              .flat_map { |cluster| cluster.occurrences.map { |o| ["class_itis", o.file] } }
        repeated = CrossCodebasePatterns.new(root: @root, output: sink).run
                                        .flat_map { |pattern| pattern.occurrences.map { |o| ["repeated_markup", o.file] } }
        similar = PartialSimilarity.new(root: @root, output: sink).run.map { ["similar_partials", nil] }
        matches = audit_violations.select { |v| v.type == :component_match }.map { |v| ["component_match", v.file] }
        class_itis + repeated + similar + matches
      end

      def accessibility
        A11yAudit.new(root: @root, output: sink).run.map { |finding| [finding.rule.to_s, finding.file] }
      end

      def audit
        @audit ||= Audit.new(root: @root, output: sink)
      end

      def audit_violations
        @audit_violations ||= audit.run
      end

      # Template findings count only in templates the audit scans, so a
      # detector that doesn't read `audit.ignore` can't push the score
      # past what `templates_scanned` covers.
      def counted?(file)
        file.nil? || !file.end_with?(".html.erb") || audit.covers?(file)
      end

      # Issues per file, for finding where a score moved.
      def by_file(found)
        files = Hash.new { |hash, file| hash[file] = Hash.new(0) }
        found.each do |bucket, entries|
          entries.each { |_type, file| files[file][bucket] += 1 if file }
        end
        files.sort.to_h { |file, counts| [file, counts.sort.to_h.merge("total" => counts.values.sum)] }
      end

      def rate(count, templates)
        templates.zero? ? nil : (count * 100.0 / templates).round(1)
      end

      def config_digest
        path = @root.join("guardrails.yml")
        path.file? ? Digest::SHA256.hexdigest(path.read)[0, 12] : nil
      end

      def git_state
        commit, ok = git("rev-parse", "--short", "HEAD")
        return nil unless ok

        status, = git("status", "--porcelain", "--untracked-files=no")
        { "commit" => commit.strip, "dirty" => !status.strip.empty? }
      end

      def git(*args)
        out, status = Open3.capture2("git", *args, chdir: @root.to_s, err: File::NULL)
        [out, status.success?]
      rescue SystemCallError
        [nil, false]
      end

      def sink
        StringIO.new
      end
    end
  end
end
