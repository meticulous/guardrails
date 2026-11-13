# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "guardrails/feed_ramp"

RSpec.describe Guardrails::FeedRamp::ModernWeb do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  def add_skill(dir)
    @root.join(dir, "modern-web-guidance").mkpath
    @root.join(dir, "modern-web-guidance", "SKILL.md").write("---\nname: modern-web-guidance\n---\n")
  end

  describe ".installed?" do
    it "is false without the skill" do
      @root.join(".claude/skills/something-else").mkpath
      expect(described_class.installed?(@root)).to be false
    end

    it "finds the skill in any agent's project skills directory" do
      add_skill(".agents/skills")
      expect(described_class.installed?(@root)).to be true
    end

    it "follows an agent's link to the shared copy" do
      add_skill(".agents/skills")
      @root.join(".claude/skills").mkpath
      File.symlink(@root.join(".agents/skills/modern-web-guidance"), @root.join(".claude/skills/modern-web-guidance"))

      expect(Dir.glob(described_class::SKILL_GLOB, base: @root.to_s))
        .to include(".claude/skills/modern-web-guidance/SKILL.md")
    end
  end

  describe described_class::Install do
    let(:output) { StringIO.new }

    def install(result, &block)
      commands = []
      runner = lambda do |*command|
        commands << command
        block&.call
        result
      end
      [described_class.new(root: @root, output: output, runner: runner), commands]
    end

    it "runs Modern Web Guidance's own installer, after crediting it and naming its telemetry" do
      installer, commands = install(true)

      expect(installer.call).to be true
      expect(commands).to eq([%w[npx -y modern-web-guidance@latest install]])
      expect(output.string).to include("Google Chrome", "Microsoft Edge", "Mozilla Firefox", "MDN",
                                       "Apache-2.0", "CC BY 4.0",
                                       "https://developer.chrome.com/docs/modern-web-guidance",
                                       "DISABLE_TELEMETRY=1")
    end

    it "passes extra arguments to the installer" do
      installer, commands = install(true)
      installer.call(%w[--agent claude-code])

      expect(commands.first.last(2)).to eq(%w[--agent claude-code])
    end

    it "points at the rules task once the skill is in the project" do
      installer, = install(true) { add_skill(".claude/skills") }
      installer.call

      expect(output.string).to include("rake ui_guardrails:feed_ramp:rules")
    end

    it "names the config key when the skill went somewhere else" do
      installer, = install(true)
      installer.call

      expect(output.string).to include("feed_ramp.modern_web_guidance: true")
    end

    it "is false when the installer fails" do
      installer, = install(false)

      expect(installer.call).to be false
      expect(output.string).not_to include("feed_ramp:rules")
    end

    it "says what's missing when npx can't be started" do
      installer, = install(nil)

      expect { installer.call }.to raise_error(Guardrails::Error, /Node\.js 22/)
    end
  end

  describe "feed_ramp.modern_web_guidance in guardrails.yml" do
    def config(yaml)
      @root.join("guardrails.yml").write(yaml)
      Guardrails::FeedRamp::Config.load(@root)
    end

    it "is unset by default, so the rules go by what's installed" do
      expect(Guardrails::FeedRamp::Config.load(@root).modern_web_guidance).to be_nil
    end

    it "reads true and false" do
      expect(config("guardrails:\n  feed_ramp:\n    modern_web_guidance: true\n").modern_web_guidance).to be true
      expect(config("guardrails:\n  feed_ramp:\n    modern_web_guidance: false\n").modern_web_guidance).to be false
    end

    it "rejects anything else" do
      expect { config("guardrails:\n  feed_ramp:\n    modern_web_guidance: sometimes\n") }
        .to raise_error(ArgumentError, /modern_web_guidance "sometimes"/)
    end
  end
end
