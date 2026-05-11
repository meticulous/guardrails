# frozen_string_literal: true

require "guardrails/configuration"

RSpec.describe Guardrails::Configuration do
  after { Guardrails.reset_configuration! }

  describe "Guardrails.configure" do
    it "yields a Configuration that round-trips back through .configuration" do
      Guardrails.configure do |c|
        c.visual_diff.enabled = true
        c.visual_diff.threshold = 0.05
        c.visual_diff.snap_diff_dir = "spec/screenshots"
      end

      expect(Guardrails.configuration.visual_diff.enabled).to be true
      expect(Guardrails.configuration.visual_diff.threshold).to eq(0.05)
      expect(Guardrails.configuration.visual_diff.snap_diff_dir).to eq("spec/screenshots")
    end

    it "is idempotent — calling configure twice merges, doesn't reset" do
      Guardrails.configure { |c| c.visual_diff.threshold = 0.05 }
      Guardrails.configure { |c| c.visual_diff.snap_diff_dir = "elsewhere" }

      expect(Guardrails.configuration.visual_diff.threshold).to eq(0.05)
      expect(Guardrails.configuration.visual_diff.snap_diff_dir).to eq("elsewhere")
    end
  end

  describe "Guardrails.reset_configuration!" do
    it "wipes prior configure block state so tests don't leak" do
      Guardrails.configure { |c| c.visual_diff.enabled = true }
      Guardrails.reset_configuration!

      expect(Guardrails.configuration.visual_diff.enabled).to be false
    end
  end

  describe "visual_diff defaults" do
    it "is opt-in by default (enabled: false)" do
      expect(Guardrails.configuration.visual_diff.enabled).to be false
    end

    it "defaults to the :snap_diff adapter" do
      expect(Guardrails.configuration.visual_diff.adapter).to eq(:snap_diff)
    end

    it "defaults snap_diff_dir to doc/screenshots (matches the gem's convention)" do
      expect(Guardrails.configuration.visual_diff.snap_diff_dir).to eq("doc/screenshots")
    end

    it "defaults threshold to 0.0 (strict — any non-zero mismatch fails)" do
      expect(Guardrails.configuration.visual_diff.threshold).to eq(0.0)
    end
  end

  describe "visual_diff.adapter=" do
    let(:vd) { Guardrails.configuration.visual_diff }

    it "accepts a known symbol" do
      vd.adapter = :backstop
      expect(vd.adapter).to eq(:backstop)
    end

    it "coerces a string to a symbol" do
      vd.adapter = "snap_diff"
      expect(vd.adapter).to eq(:snap_diff)
    end

    it "rejects unknown adapters with a helpful error" do
      expect { vd.adapter = :percy }.to raise_error(ArgumentError, /Unknown visual_diff adapter :percy/)
    end

    it "rejects nil with a clear ArgumentError (not NoMethodError on to_sym)" do
      expect { vd.adapter = nil }.to raise_error(ArgumentError, /cannot be nil/)
    end

    it "rejects a blank string" do
      expect { vd.adapter = "" }.to raise_error(ArgumentError, /cannot be blank/)
      expect { vd.adapter = "   " }.to raise_error(ArgumentError, /cannot be blank/)
    end
  end

  describe "visual_diff.threshold=" do
    let(:vd) { Guardrails.configuration.visual_diff }

    it "accepts a Float in [0.0, 1.0]" do
      vd.threshold = 0.25
      expect(vd.threshold).to eq(0.25)
    end

    it "coerces an Integer to a Float" do
      vd.threshold = 0
      expect(vd.threshold).to eq(0.0)
    end

    it "coerces a numeric string" do
      vd.threshold = "0.1"
      expect(vd.threshold).to eq(0.1)
    end

    it "rejects negative values" do
      expect { vd.threshold = -0.1 }.to raise_error(ArgumentError, /between 0.0 and 1.0/)
    end

    it "rejects values above 1.0 (mismatch is a ratio, not a percentage)" do
      expect { vd.threshold = 1.5 }.to raise_error(ArgumentError, /between 0.0 and 1.0/)
    end

    it "rejects non-numeric strings" do
      expect { vd.threshold = "not a number" }.to raise_error(ArgumentError)
    end

    it "rejects nil with a clear ArgumentError (not TypeError on Float)" do
      expect { vd.threshold = nil }.to raise_error(ArgumentError, /cannot be nil/)
    end

    it "rejects a blank string" do
      expect { vd.threshold = "" }.to raise_error(ArgumentError, /cannot be blank/)
      expect { vd.threshold = "   " }.to raise_error(ArgumentError, /cannot be blank/)
    end
  end
end
