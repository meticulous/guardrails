# frozen_string_literal: true

RSpec.describe Guardrails do
  it "has a version number" do
    expect(Guardrails::VERSION).not_to be_nil
  end

  # The `Guardrails.configure { |c| c.visual_diff.enabled = true }` block
  # lives in `config/initializers/guardrails.rb` for embedded installs.
  # That initializer is invoked after `require "guardrails"` and nothing
  # else — if configuration.rb isn't auto-loaded by the top-level entry,
  # the initializer NoMethodErrors on first boot. Caught by 1.0.0's
  # local-build verification; locking in here so a future refactor of
  # `lib/guardrails.rb` doesn't silently regress.
  describe "require \"guardrails\"" do
    it "exposes Guardrails.configure (Configuration auto-loaded)" do
      expect(described_class).to respond_to(:configure)
      expect(described_class).to respond_to(:configuration)
    end

    it "yields a usable Configuration in the block" do
      expect {
        described_class.configure { |c| c.visual_diff.enabled = true }
      }.not_to raise_error
      expect(described_class.configuration.visual_diff.enabled).to be true
    ensure
      described_class.reset_configuration!
    end
  end
end
