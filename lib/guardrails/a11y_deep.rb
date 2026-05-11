# frozen_string_literal: true

require "json"
require "pathname"
require "set"
require_relative "report/style"

module Guardrails
  # Consumes axe-core JSON output and folds the findings into Guardrails'
  # unified report. Distinct from `A11yAudit`, which runs static template
  # checks (image_alt, button_name, etc.) without rendering.
  #
  # Why parse-only, no run: bundling axe-core means bundling Capybara +
  # headless Chrome as runtime deps of a static-analysis gem — too heavy
  # for users who don't run system tests. Instead, users run axe-core
  # however they already do (axe-core-rspec, `npx @axe-core/cli`, a
  # CDP-driven script) and pass the JSON output to Guardrails:
  #
  #     npx @axe-core/cli http://localhost:3000/ --save axe.json
  #     AXE_JSON=axe.json bundle exec rake guardrails:audit
  #
  # The result is a single unified report — static findings from
  # A11yAudit plus runtime findings from axe — with the same exit-code
  # semantics as the rest of the audit.
  class A11yDeep
    Finding = Struct.new(:rule, :impact, :description, :help_url, :url, :selector, keyword_init: true) do
      def to_h
        super
      end
    end

    # Impacts we treat as audit-failing. axe emits one of: minor, moderate,
    # serious, critical (and sometimes nil for `incomplete` findings or
    # custom rule packs). The 0.6.0 default is "any known non-nil impact
    # fails" — covers axe's full impact ladder and aligns with the static
    # a11y rules which all fail unconditionally. Findings with a nil/
    # unknown impact do NOT fail by default; tighten per-call via
    # `failing_impacts:` if your rule pack emits custom severities.
    DEFAULT_FAILING_IMPACTS = %w[minor moderate serious critical].freeze

    def initialize(input:, output: $stdout, failing_impacts: DEFAULT_FAILING_IMPACTS, style: nil)
      @input = input
      @output = output
      @failing_impacts = Set.new(failing_impacts.map(&:to_s))
      @style = style || Report::Style.new(io: output)
    end

    def run
      findings = parse_input
      print_report(findings)
      findings
    end

    # Parse axe-core JSON. Accepts either a single result object
    # `{ "url": "...", "violations": [...] }` or an array of results
    # (multi-page runs, what `axe-core/cli --save` produces). Returns
    # a flat list of Finding structs.
    def parse(payload)
      pages = payload.is_a?(Array) ? payload : [payload]
      pages.flat_map { |page| parse_page(page) }
    end

    def any_failing?(findings)
      findings.any? { |f| @failing_impacts.include?(f.impact.to_s) }
    end

    private

    def parse_input
      raw = @input.is_a?(Hash) || @input.is_a?(Array) ? @input : JSON.parse(File.read(@input.to_s, encoding: Encoding::UTF_8))
      parse(raw)
    rescue Errno::ENOENT
      @output.puts "Guardrails a11y (deep): #{@input} not found — skipping"
      []
    rescue JSON::ParserError => e
      @output.puts "Guardrails a11y (deep): could not parse #{@input} — #{e.message}"
      []
    end

    def parse_page(page)
      return [] unless page.is_a?(Hash)

      url = page["url"]
      Array(page["violations"]).flat_map do |violation|
        rule = violation["id"]
        impact = violation["impact"]
        description = violation["help"] || violation["description"]
        help_url = violation["helpUrl"]
        Array(violation["nodes"]).map do |node|
          Finding.new(
            rule: rule,
            impact: impact,
            description: description,
            help_url: help_url,
            url: url,
            selector: Array(node["target"]).first
          )
        end
      end
    end

    def print_report(findings)
      return if findings.empty?

      grouped = findings.group_by(&:url)
      noun = findings.length == 1 ? "finding" : "findings"

      @output.puts ""
      @output.puts @style.section_heading(
        :error,
        "a11y deep (#{findings.length} #{noun} from axe-core)"
      )
      @output.puts "  Runtime accessibility issues axe-core caught against your live pages."
      @output.puts "  Each links to dequeuniversity.com for the canonical remediation."

      grouped.each do |url, page_findings|
        @output.puts ""
        @output.puts "  #{@style.location(url || '(no url)')}"
        page_findings.each do |f|
          severity = impact_to_severity(f.impact)
          impact_label = f.impact ? f.impact.to_s : "unknown"
          selector_part = f.selector ? " (#{f.selector})" : ""
          @output.puts "    #{@style.severity(severity, "[#{impact_label}] #{f.rule}: #{f.description}#{selector_part}")}"
          @output.puts "      #{@style.suggestion("see #{f.help_url}")}" if f.help_url
        end
      end
    end

    # Map axe-core's impact levels onto the report's three severities
    # so they color-code consistently with static a11y findings.
    def impact_to_severity(impact)
      case impact.to_s
      when "critical", "serious" then :error
      when "moderate" then :warning
      when "minor" then :suggestion
      else :warning
      end
    end
  end
end
