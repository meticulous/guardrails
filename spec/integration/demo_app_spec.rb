# frozen_string_literal: true

require "stringio"
require "guardrails/audit"
require "guardrails/icons"
require "guardrails/tokens"
require "guardrails/stimulus_audit"
require "guardrails/partial_similarity"
require "guardrails/view_component_audit"
require "guardrails/a11y_audit"
require "guardrails/lookbook/component_report"

# End-to-end integration coverage against examples/demo. Asserting concrete
# counts here so any change to detector behavior surfaces immediately —
# either intentionally (update the expected counts) or as a regression.
RSpec.describe "examples/demo" do
  let(:root) { Pathname(File.expand_path("../../examples/demo", __dir__)) }

  it "exists" do
    expect(root).to exist
  end

  describe "guardrails:audit (view violations)" do
    it "reports the seeded view drift" do
      violations = Guardrails::Audit.new(root: root, output: StringIO.new).run

      types = violations.map(&:type).tally
      expect(types[:inline_style]).to eq(1)
      expect(types[:raw_color]).to eq(3)
      expect(types[:tailwind_arbitrary]).to eq(2)
    end
  end

  describe "guardrails:audit (stimulus)" do
    it "reports one orphan and one dead controller" do
      result = Guardrails::StimulusAudit.new(root: root, output: StringIO.new).run

      expect(result.orphaned).to eq(["missing"])
      expect(result.dead).to eq(["dead"])
    end
  end

  describe "guardrails:audit (partial similarity)" do
    it "flags the seeded similar pairs" do
      findings = Guardrails::PartialSimilarity.new(root: root, output: StringIO.new).run

      pairs = findings.map { |f| [f.file_a, f.file_b].sort }
      expect(pairs).to include(
        ["app/components/button_component.html.erb", "app/components/icon_button_component.html.erb"],
        ["app/views/shared/_hero_card.html.erb", "app/views/shared/_hero_card_alt.html.erb"]
      )
    end
  end

  describe "guardrails:audit (view components)" do
    it "flags missing previews and orphan slots" do
      result = Guardrails::ViewComponentAudit.new(root: root, output: StringIO.new).run

      expect(result.missing_previews).to include("card", "icon_button")
      expect(result.missing_previews).not_to include("button")
      expect(result.orphan_slots.map(&:slot)).to include("unused_actions")
    end
  end

  describe "guardrails:audit (static a11y)" do
    it "flags seeded a11y issues in welcome/broken.html.erb" do
      findings = Guardrails::A11yAudit.new(root: root, output: StringIO.new).run

      broken_findings = findings.select { |f| f.file == "app/views/welcome/broken.html.erb" }
      rules = broken_findings.map(&:rule)

      expect(rules).to include(:image_alt, :button_name, :link_name)
    end
  end

  describe "guardrails:icons" do
    around do |example|
      sprite = root.join("app/assets/images/icons/sprite.svg")
      sprite_existed = sprite.exist?
      original_content = sprite_existed ? sprite.read(encoding: Encoding::UTF_8) : nil

      example.run

      if sprite_existed
        sprite.write(original_content)
      else
        sprite.delete if sprite.exist?
      end
    end

    it "generates a sprite, flags inline SVGs, and reports dead icons" do
      result = Guardrails::Icons.new(root: root, output: StringIO.new).run

      expect(root.join("app/assets/images/icons/sprite.svg")).to exist
      expect(result[:inline_svgs].length).to be >= 1
      expect(result[:dead_icons]).to include("search")
    end
  end

  describe "guardrails:tokens" do
    it "parses defined tokens and reports drift in stylesheets" do
      result = Guardrails::Tokens.new(root: root, output: StringIO.new).run

      token_names = result[:tokens].map(&:name)
      expect(token_names).to include("primary-500", "neutral-100", "secondary-500")

      drift_values = result[:drift].map(&:value)
      expect(drift_values).to include("#0066ff", "#abcdef")

      matched = result[:drift].find { |d| d.value == "#0066ff" }
      expect(matched.matched_token.name).to eq("primary-500")

      unmatched = result[:drift].find { |d| d.value == "#abcdef" }
      expect(unmatched.matched_token).to be_nil
    end
  end

  describe "Lookbook component report" do
    it "returns findings for the seeded broken card component" do
      report = Guardrails::Lookbook::ComponentReport.new(root: root).for("CardComponent")

      expect(report[:component]).to eq("CardComponent")
      expect(report[:orphan_slots].map { |s| s[:slot] }).to include("unused_actions")
    end

    it "returns nil for a component that doesn't exist" do
      report = Guardrails::Lookbook::ComponentReport.new(root: root).for("NotARealComponent")
      expect(report).to be_nil
    end
  end
end
