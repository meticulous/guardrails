# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "guardrails/a11y_deep"

RSpec.describe Guardrails::A11yDeep do
  let(:output) { StringIO.new }

  # Realistic axe-core v4 single-page output shape (trimmed).
  def axe_single_page
    {
      "url" => "http://localhost:3000/",
      "violations" => [
        {
          "id" => "color-contrast",
          "impact" => "serious",
          "tags" => %w[wcag2aa],
          "description" => "Ensures elements have sufficient color contrast",
          "help" => "Elements must have sufficient color contrast",
          "helpUrl" => "https://dequeuniversity.com/rules/axe/4.7/color-contrast",
          "nodes" => [
            {
              "target" => [".btn-primary"],
              "html" => "<button class=\"btn-primary\">Click</button>"
            }
          ]
        },
        {
          "id" => "image-alt",
          "impact" => "critical",
          "description" => "Ensures <img> have alt text",
          "help" => "Images must have alternate text",
          "helpUrl" => "https://dequeuniversity.com/rules/axe/4.7/image-alt",
          "nodes" => [
            { "target" => ["img.logo"] },
            { "target" => ["img.hero"] }
          ]
        }
      ]
    }
  end

  describe "#parse" do
    it "returns an empty list for an axe result with no violations" do
      findings = described_class.new(input: nil, output: output).parse("url" => "/", "violations" => [])
      expect(findings).to be_empty
    end

    it "flattens each axe node into a Finding (one violation can have many nodes)" do
      findings = described_class.new(input: nil, output: output).parse(axe_single_page)
      rules = findings.map(&:rule)
      expect(rules).to eq(%w[color-contrast image-alt image-alt])
    end

    it "carries impact, description, help_url, url, and selector through" do
      findings = described_class.new(input: nil, output: output).parse(axe_single_page)
      first = findings.first
      expect(first.rule).to eq("color-contrast")
      expect(first.impact).to eq("serious")
      expect(first.description).to eq("Elements must have sufficient color contrast")
      expect(first.help_url).to start_with("https://dequeuniversity.com")
      expect(first.url).to eq("http://localhost:3000/")
      expect(first.selector).to eq(".btn-primary")
    end

    it "accepts an array of page results (multi-URL run)" do
      page_a = axe_single_page
      page_b = { "url" => "http://localhost:3000/about", "violations" => [
        { "id" => "label", "impact" => "moderate", "help" => "Form fields need labels",
          "nodes" => [{ "target" => ["input#email"] }] }
      ] }

      findings = described_class.new(input: nil, output: output).parse([page_a, page_b])
      urls = findings.map(&:url).uniq
      expect(urls).to eq(["http://localhost:3000/", "http://localhost:3000/about"])
    end

    it "falls back to description when `help` is absent" do
      payload = {
        "url" => "/", "violations" => [
          { "id" => "x", "impact" => "minor", "description" => "Fallback text", "nodes" => [{ "target" => ["body"] }] }
        ]
      }
      findings = described_class.new(input: nil, output: output).parse(payload)
      expect(findings.first.description).to eq("Fallback text")
    end

    it "tolerates a node with no `target` array" do
      payload = {
        "url" => "/", "violations" => [
          { "id" => "x", "impact" => "minor", "help" => "h", "nodes" => [{ }] }
        ]
      }
      expect { described_class.new(input: nil, output: output).parse(payload) }.not_to raise_error
    end

    it "tolerates a page with no `violations` key" do
      findings = described_class.new(input: nil, output: output).parse("url" => "/")
      expect(findings).to be_empty
    end
  end

  describe "#run" do
    it "reads a JSON file path, parses, and prints" do
      Dir.mktmpdir do |dir|
        path = Pathname(dir).join("axe.json")
        path.write(JSON.generate(axe_single_page))

        findings = described_class.new(input: path, output: output).run
        expect(findings.length).to eq(3)
        expect(output.string).to include("Guardrails a11y (deep): 3 findings from axe-core")
        expect(output.string).to include("http://localhost:3000/")
        expect(output.string).to include("[serious] color-contrast")
        expect(output.string).to include("(.btn-primary)")
        expect(output.string).to include("https://dequeuniversity.com")
      end
    end

    it "accepts an already-parsed Hash as input (skips file read)" do
      findings = described_class.new(input: axe_single_page, output: output).run
      expect(findings.length).to eq(3)
    end

    it "accepts an Array of page results as input" do
      input = [axe_single_page, { "url" => "/about", "violations" => [] }]
      findings = described_class.new(input: input, output: output).run
      expect(findings.length).to eq(3)
    end

    it "is silent when the input has no findings" do
      described_class.new(input: { "url" => "/", "violations" => [] }, output: output).run
      expect(output.string).to eq("")
    end

    it "warns and returns [] when the input file doesn't exist" do
      findings = described_class.new(input: "/no/such/file.json", output: output).run
      expect(findings).to be_empty
      expect(output.string).to include("not found")
    end

    it "warns and returns [] when the input is malformed JSON" do
      Dir.mktmpdir do |dir|
        path = Pathname(dir).join("broken.json")
        path.write("{not valid json")
        findings = described_class.new(input: path, output: output).run
        expect(findings).to be_empty
        expect(output.string).to include("could not parse")
      end
    end

    it "groups findings by URL in the report" do
      payload = [
        axe_single_page,
        { "url" => "http://localhost:3000/about",
          "violations" => [
            { "id" => "label", "impact" => "moderate", "help" => "Form fields need labels",
              "nodes" => [{ "target" => ["input#email"] }] }
          ] }
      ]
      described_class.new(input: payload, output: output).run

      lines = output.string.lines
      home_idx = lines.index { |l| l.include?("http://localhost:3000/\n") }
      about_idx = lines.index { |l| l.include?("http://localhost:3000/about") }
      expect(home_idx).not_to be_nil
      expect(about_idx).not_to be_nil
      expect(about_idx).to be > home_idx
    end
  end

  describe "#any_failing?" do
    it "returns true when at least one finding's impact is in the failing set" do
      payload = {
        "url" => "/", "violations" => [
          { "id" => "x", "impact" => "serious", "help" => "h",
            "nodes" => [{ "target" => ["body"] }] }
        ]
      }
      audit = described_class.new(input: payload, output: output)
      findings = audit.run
      expect(audit.any_failing?(findings)).to be true
    end

    it "respects a custom failing_impacts list (e.g. critical-only)" do
      payload = {
        "url" => "/", "violations" => [
          { "id" => "x", "impact" => "serious", "help" => "h",
            "nodes" => [{ "target" => ["body"] }] }
        ]
      }
      audit = described_class.new(input: payload, output: output, failing_impacts: %w[critical])
      findings = audit.run
      expect(audit.any_failing?(findings)).to be false
    end

    it "returns false when findings is empty" do
      audit = described_class.new(input: { "url" => "/", "violations" => [] }, output: output)
      expect(audit.any_failing?(audit.run)).to be false
    end
  end
end
