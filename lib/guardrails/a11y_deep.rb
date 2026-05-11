# frozen_string_literal: true

require "json"
require "pathname"

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
    # serious, critical (and sometimes nil for `incomplete` findings). The
    # 0.6.0 default is "any impact fails" — same shape as static a11y rules
    # which all fail unconditionally. Configurable per-call if needed.
    DEFAULT_FAILING_IMPACTS = %w[minor moderate serious critical].freeze

    def initialize(input:, output: $stdout, failing_impacts: DEFAULT_FAILING_IMPACTS)
      @input = input
      @output = output
      @failing_impacts = Set.new(failing_impacts.map(&:to_s))
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
      @output.puts ""
      @output.puts "Guardrails a11y (deep): #{findings.length} finding#{'s' if findings.length != 1} from axe-core"

      grouped.each do |url, page_findings|
        @output.puts ""
        @output.puts "  #{url || '(no url)'}"
        page_findings.each do |f|
          impact_label = f.impact ? "[#{f.impact}]" : "[unknown]"
          selector = f.selector ? " (#{f.selector})" : ""
          @output.puts "    #{impact_label} #{f.rule} — #{f.description}#{selector}"
          @output.puts "      #{f.help_url}" if f.help_url
        end
      end
    end
  end
end
