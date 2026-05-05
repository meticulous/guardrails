# frozen_string_literal: true

require "guardrails/tokens/tailwind_config_parser"

RSpec.describe Guardrails::Tokens::TailwindConfigParser do
  describe ".parse" do
    it "returns an empty list when the input has no colors block" do
      expect(described_class.parse("module.exports = {};")).to be_empty
    end

    it "parses flat colors at theme.colors" do
      js = <<~JS
        module.exports = {
          theme: {
            colors: {
              primary: "#0066ff",
              secondary: "#fa3"
            }
          }
        }
      JS

      entries = described_class.parse(js)
      expect(entries.map(&:name)).to eq(%w[primary secondary])
      expect(entries.map(&:value)).to eq(%w[#0066ff #fa3])
    end

    it "parses flat colors at theme.extend.colors" do
      js = <<~JS
        module.exports = {
          theme: {
            extend: {
              colors: {
                accent: "#ffaa33"
              }
            }
          }
        }
      JS

      entries = described_class.parse(js)
      expect(entries.length).to eq(1)
      expect(entries.first.name).to eq("accent")
    end

    it "flattens nested color scales using Tailwind's name-key convention" do
      js = <<~JS
        module.exports = {
          theme: {
            colors: {
              gray: {
                50: "#f9fafb",
                100: "#f3f4f6",
                900: "#111827"
              }
            }
          }
        }
      JS

      entries = described_class.parse(js)
      names = entries.map(&:name)
      expect(names).to eq(%w[gray-50 gray-100 gray-900])
    end

    it "handles single-quoted values" do
      js = "module.exports = { theme: { colors: { primary: '#0066ff' } } }"

      entries = described_class.parse(js)
      expect(entries.first.value).to eq("#0066ff")
    end

    it "handles quoted keys" do
      js = 'module.exports = { theme: { colors: { "primary-500": "#0066ff" } } }'

      entries = described_class.parse(js)
      expect(entries.first.name).to eq("primary-500")
    end

    it "skips entries with function-valued or otherwise unparseable values" do
      js = <<~JS
        module.exports = {
          theme: {
            colors: {
              dynamic: defineColor("primary"),
              primary: "#0066ff"
            }
          }
        }
      JS

      entries = described_class.parse(js)
      expect(entries.map(&:name)).to eq(["primary"])
    end

    it "ignores spread operators inside the colors block" do
      js = <<~JS
        module.exports = {
          theme: {
            colors: {
              ...basePalette,
              primary: "#0066ff"
            }
          }
        }
      JS

      entries = described_class.parse(js)
      expect(entries.map(&:name)).to eq(["primary"])
    end

    it "parses both top-level theme.colors and theme.extend.colors when both exist" do
      js = <<~JS
        module.exports = {
          theme: {
            colors: {
              brand: "#0066ff"
            },
            extend: {
              colors: {
                accent: "#ffaa33"
              }
            }
          }
        }
      JS

      entries = described_class.parse(js)
      expect(entries.map(&:name)).to contain_exactly("brand", "accent")
    end

    it "ignores malformed JS gracefully (no exceptions)" do
      js = "module.exports = { theme: { colors: { primary: \"#0066ff\""

      expect { described_class.parse(js) }.not_to raise_error
    end

    it "parses an export default config (TS-style)" do
      js = <<~JS
        export default {
          theme: {
            colors: {
              primary: "#0066ff"
            }
          }
        }
      JS

      entries = described_class.parse(js)
      expect(entries.first.name).to eq("primary")
    end
  end
end
