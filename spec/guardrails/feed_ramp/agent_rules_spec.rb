# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "guardrails/feed_ramp"

RSpec.describe Guardrails::FeedRamp::AgentRules do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  let(:manifest) do
    {
      "components" => [
        { "name" => "ButtonComponent", "description" => "The app's button. Use it for every action." },
        { "name" => "IconComponent", "description" => nil }
      ],
      "tokens" => [
        { "name" => "--color-brand", "category" => "color" },
        { "name" => "--space-2", "category" => "spacing" }
      ]
    }
  end

  def rules(targets: described_class::DEFAULT_TARGETS, data: manifest)
    described_class.new(root: @root, manifest: data, manifest_path: ".ui_guardrails/manifest.json",
                        markdown_path: ".ui_guardrails/COMPONENTS.md", targets: targets,
                        component_paths: %w[app/components app/views/components])
  end

  def write_file(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def read(path)
    @root.join(path).read
  end

  def statuses(changes)
    changes.to_h { |change| [change.target, change.status] }
  end

  describe "the block" do
    it "points at the component list and names each component and token category" do
      block = rules.block
      expect(block).to start_with(described_class::BEGIN_MARKER)
      expect(block).to end_with(described_class::END_MARKER)
      expect(block).to include("`.ui_guardrails/COMPONENTS.md`", "`.ui_guardrails/manifest.json`",
                               "- `ButtonComponent` — The app's button.\n", "- `IconComponent`\n",
                               "- color (1): `--color-brand`", "rake ui_guardrails:audit")
    end

    it "caps the component list and says where the rest are" do
      many = manifest.merge("components" => Array.new(60) { |i| { "name" => format("C%02dComponent", i) } })
      block = rules(data: many).block
      expect(block).to include("Components (60):", "`C49Component`", "- …and 10 more in `.ui_guardrails/COMPONENTS.md`.")
      expect(block).not_to include("`C50Component`")
    end

    it "leaves out the component and token advice when there are none" do
      block = rules(data: { "components" => [], "tokens" => [] }).block
      expect(block).not_to include("Components (", "Design tokens (", "component library")
      expect(block).to include("rake ui_guardrails:audit")
    end
  end

  describe "#write" do
    it "creates CLAUDE.md, AGENTS.md and the Cursor rule by default" do
      expect(statuses(rules.write)).to eq("claude" => :created, "agents" => :created, "cursor" => :created)
      expect(read("CLAUDE.md")).to eq("#{rules.block}\n")
      expect(read("AGENTS.md")).to eq("#{rules.block}\n")
      expect(read(".cursor/rules/ui-guardrails.mdc")).to start_with(<<~MDC)
        ---
        description: Use this app's UI components and design tokens instead of writing markup by hand
        globs: app/views/**/*,app/components/**/*
        alwaysApply: false
        ---
      MDC
    end

    it "changes nothing the second time" do
      rules.write
      before = %w[CLAUDE.md AGENTS.md .cursor/rules/ui-guardrails.mdc].to_h { |path| [path, read(path)] }

      expect(rules.write.map(&:status).uniq).to eq([:unchanged])
      expect(before.to_h { |path, _| [path, read(path)] }).to eq(before)
    end

    it "adds the block after the user's content, leaving it as it was" do
      write_file("CLAUDE.md", "# Project\n\nRun `bin/test`.\n\n\n")
      rules(targets: %w[claude]).write
      expect(read("CLAUDE.md")).to eq("# Project\n\nRun `bin/test`.\n\n#{rules.block}\n")
    end

    it "replaces only what's between the markers, wherever the block is" do
      write_file("AGENTS.md", "Intro\n\n#{described_class::BEGIN_MARKER}\nold rules\n#{described_class::END_MARKER}\n\n## Mine\n- keep\n")
      expect(statuses(rules(targets: %w[agents]).write)).to eq("agents" => :updated)
      expect(read("AGENTS.md")).to eq("Intro\n\n#{rules.block}\n\n## Mine\n- keep\n")
    end

    it "updates the block when the manifest changes" do
      rules(targets: %w[claude]).write
      changed = manifest.merge("components" => manifest["components"] + [{ "name" => "CardComponent" }])

      expect(statuses(rules(targets: %w[claude], data: changed).write)).to eq("claude" => :updated)
      expect(read("CLAUDE.md")).to include("`CardComponent`")
      expect(read("CLAUDE.md").scan(described_class::BEGIN_MARKER).length).to eq(1)
    end

    it "keeps Windows line endings" do
      write_file("CLAUDE.md", "# Project\r\nNotes\r\n")
      rules(targets: %w[claude]).write
      text = read("CLAUDE.md")
      expect(text).to start_with("# Project\r\nNotes\r\n\r\n#{described_class::BEGIN_MARKER}\r\n")
      expect(text.scan(/(?<!\r)\n/)).to be_empty
      expect(rules(targets: %w[claude]).write.first.status).to eq(:unchanged)
    end

    it "refuses a file with unpaired, duplicated or reversed markers, and writes nothing to it" do
      b = described_class::BEGIN_MARKER
      e = described_class::END_MARKER
      ["x\n#{b}\n", "x\n#{e}\n", "#{b}\n#{e}\n#{b}\n#{e}\n", "#{e}\n#{b}\n"].each do |broken|
        write_file("AGENTS.md", broken)
        expect { rules(targets: %w[agents]).write }.to raise_error(Guardrails::Error, /AGENTS\.md: expected one/)
        expect(read("AGENTS.md")).to eq(broken)
      end
    end

    it "won't overwrite a Cursor rule it didn't write" do
      write_file(".cursor/rules/ui-guardrails.mdc", "---\nalwaysApply: true\n---\nMine\n")
      expect { rules(targets: %w[cursor]).write }.to raise_error(Guardrails::Error, /wasn't written by ui_guardrails/)
      expect(read(".cursor/rules/ui-guardrails.mdc")).to eq("---\nalwaysApply: true\n---\nMine\n")
    end

    it "writes GEMINI.md and Copilot's instructions when asked" do
      expect(statuses(rules(targets: %w[gemini copilot]).write)).to eq("gemini" => :created, "copilot" => :created)
      expect(read(".github/copilot-instructions.md")).to eq("#{rules.block}\n")
    end

    it "rejects an unknown target" do
      expect { rules(targets: %w[claude windsurf]) }.to raise_error(Guardrails::Error, /Unknown agent rules target windsurf/)
    end

    it "skips CLAUDE.md when it imports AGENTS.md, taking out a block written before the import" do
      write_file("CLAUDE.md", "@AGENTS.md\n\n#{rules.block}\n")
      changes = rules(targets: %w[claude agents]).write
      expect(changes.first).to have_attributes(target: "claude", status: :removed, reason: "imports AGENTS.md")
      expect(read("CLAUDE.md")).to eq("@AGENTS.md\n")

      expect(rules(targets: %w[claude agents]).write.first).to have_attributes(status: :skipped)
      expect(read("AGENTS.md")).to include(described_class::BEGIN_MARKER)
    end

    it "writes CLAUDE.md that imports AGENTS.md when AGENTS.md isn't a target" do
      write_file("CLAUDE.md", "@AGENTS.md\n")
      expect(statuses(rules(targets: %w[claude]).write)).to eq("claude" => :updated)
    end

    it "writes a file once when CLAUDE.md is a link to AGENTS.md" do
      write_file("AGENTS.md", "Shared\n")
      File.symlink("AGENTS.md", @root.join("CLAUDE.md"))
      changes = rules(targets: %w[agents claude]).write
      expect(changes.map(&:status)).to eq(%i[updated skipped])
      expect(changes.last.reason).to eq("same file as AGENTS.md")
      expect(read("AGENTS.md").scan(described_class::BEGIN_MARKER).length).to eq(1)
    end
  end

  describe "#stale" do
    it "lists targets that are missing or out of date, and is empty once written" do
      expect(rules.stale.map(&:target)).to eq(%w[claude agents cursor])
      rules.write
      expect(rules.stale).to be_empty

      write_file("AGENTS.md", read("AGENTS.md").sub("The app's button.", "Edited by hand."))
      expect(rules.stale.map(&:target)).to eq(%w[agents])
      expect(read("AGENTS.md")).to include("Edited by hand.")
    end
  end

  describe "#remove" do
    it "takes out the block and leaves the user's content exactly as before" do
      original = "# Project\n\nRun `bin/test`.\n"
      write_file("CLAUDE.md", original)
      write_file("AGENTS.md", "Top\n\n#{described_class::BEGIN_MARKER}\nx\n#{described_class::END_MARKER}\n\nBottom\n")
      rules.write

      expect(statuses(rules.remove)).to eq("claude" => :removed, "agents" => :removed, "cursor" => :removed)
      expect(read("CLAUDE.md")).to eq(original)
      expect(read("AGENTS.md")).to eq("Top\n\nBottom\n")
      expect(@root.join(".cursor/rules")).not_to exist
    end

    it "deletes a file that held only the block" do
      rules(targets: %w[agents]).write
      rules(targets: %w[agents]).remove
      expect(@root.join("AGENTS.md")).not_to exist
    end
  end

  describe ".for" do
    let(:fixture) { Pathname(File.expand_path("../../fixtures/feed_ramp_app", __dir__)) }

    it "builds the block from a manifest and its config" do
      FileUtils.cp_r("#{fixture}/.", @root)
      write_file("guardrails.yml", "guardrails:\n  feed_ramp:\n    output_dir: docs/agents\n    rules_targets: [agents]\n")
      built = described_class.for(Guardrails::FeedRamp::Manifest.new(root: @root))

      expect(statuses(built.write)).to eq("agents" => :created)
      expect(read("AGENTS.md")).to include("`docs/agents/COMPONENTS.md`", "Components (6):", "- `Admin::BadgeComponent` — ")
    end
  end
end
