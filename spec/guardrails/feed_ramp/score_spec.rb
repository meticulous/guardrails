# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "guardrails/feed_ramp"

RSpec.describe Guardrails::FeedRamp::Score do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  let(:noon) { Time.utc(2026, 10, 19, 12) }

  def write_file(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def score(at: noon)
    described_class.new(root: @root, clock: -> { at })
  end

  def seed_app
    write_file("app/views/pages/home.html.erb",
               %(<div style="color: #ff0000">Hi</div>\n<p class="bg-[#123456]">x</p>\n<img src="a.png">\n))
    write_file("app/views/pages/about.html.erb", "<p>About</p>\n")
    write_file("app/assets/stylesheets/app.css", ".x { color: #abcdef; }\n")
    4.times do |i|
      write_file("app/views/pages/card#{i}.html.erb",
                 %(<div class="flex items-center justify-between rounded-lg border p-4 shadow">x</div>\n))
    end
  end

  describe "#to_h" do
    before { seed_app }

    it "counts each bucket by type, per 100 templates" do
      data = score.to_h
      expect(data).to include("schema_version" => 1, "generator" => "ui_guardrails #{Guardrails::VERSION}",
                              "generated_at" => "2026-10-19T12:00:00Z", "templates_scanned" => 6,
                              "totals" => { "issues" => 8, "per_100_templates" => 133.3 })
      expect(data["buckets"]).to eq(
        "hardcoded_values" => { "count" => 3, "per_100_templates" => 50.0,
                                "by_type" => { "inline_style" => 1, "stylesheet_color" => 1, "tailwind_arbitrary" => 1 } },
        "reinvented_components" => { "count" => 4, "per_100_templates" => 66.7, "by_type" => { "class_itis" => 4 } },
        "accessibility" => { "count" => 1, "per_100_templates" => 16.7, "by_type" => { "image_alt" => 1 } }
      )
    end

    it "breaks the issues down by file" do
      expect(score.to_h["files"]).to include(
        "app/views/pages/home.html.erb" => { "accessibility" => 1, "hardcoded_values" => 2, "total" => 3 },
        "app/assets/stylesheets/app.css" => { "hardcoded_values" => 1, "total" => 1 },
        "app/views/pages/card0.html.erb" => { "reinvented_components" => 1, "total" => 1 }
      )
      expect(score.to_h["files"]).not_to have_key("app/views/pages/about.html.erb")
    end

    it "leaves out templates the audit ignores, from every bucket" do
      write_file("app/views/layouts/application.html.erb", %(<img src="logo.png">\n<div style="margin: 0">x</div>\n))
      write_file("guardrails.yml", "guardrails:\n  audit:\n    ignore:\n      - app/views/layouts\n")

      data = score.to_h
      expect(data["templates_scanned"]).to eq(6)
      expect(data["totals"]["issues"]).to eq(8)
      expect(data["files"].keys.grep(/layouts/)).to be_empty
    end

    it "ignores the audit's env vars, so runs stay comparable" do
      before = score.to_h
      original = ENV.to_h.slice("CLASSITIS_MIN_OCCURRENCES", "SEVERITY")
      ENV["CLASSITIS_MIN_OCCURRENCES"] = "99"
      ENV["SEVERITY"] = "error"
      expect(score.to_h).to eq(before)
    ensure
      %w[CLASSITIS_MIN_OCCURRENCES SEVERITY].each { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
    end

    it "records the guardrails.yml digest and the git commit" do
      expect(score.to_h).to include("config_digest" => nil, "git" => nil)

      write_file("guardrails.yml", "guardrails: {}\n")
      git = ->(*args) { Open3.capture3("git", "-c", "user.email=t@example.com", "-c", "user.name=T", *args, chdir: @root.to_s) }
      git.call("init", "-q")
      git.call("add", ".")
      git.call("commit", "-qm", "init")
      data = score.to_h
      expect(data["config_digest"]).to match(/\A\h{12}\z/)
      expect(data["git"]).to match("commit" => /\A\h+\z/, "dirty" => false)

      write_file("app/views/pages/about.html.erb", "<p>Changed</p>\n")
      expect(score.to_h["git"]["dirty"]).to be true
    end
  end

  it "has no rate when there are no templates" do
    data = score.to_h
    expect(data).to include("templates_scanned" => 0, "totals" => { "issues" => 0, "per_100_templates" => nil })
    expect(described_class.summary(data)).to start_with("UI drift score: no templates scanned (0 issues in 0 templates)")
  end

  describe "#write and #latest" do
    it "saves under .ui_guardrails/scores, named by time, kept out of git" do
      seed_app
      first = score.write
      expect(first.relative_path_from(@root).to_s).to eq(".ui_guardrails/scores/20261019T120000Z.json")
      expect(JSON.parse(first.read)).to eq(score.to_h)
      expect(@root.join(".ui_guardrails/scores/.gitignore").read).to end_with("*\n")

      later = score(at: noon + 60).write
      expect(score.latest).to eq(later)
    end

    it "uses the configured output_dir" do
      write_file("guardrails.yml", "guardrails:\n  feed_ramp:\n    output_dir: tmp/ui\n")
      expect(score.write.relative_path_from(@root).to_s).to start_with("tmp/ui/scores/")
    end

    it "has no latest score before the first" do
      expect(score.latest).to be_nil
    end
  end

  describe ".compare and .summary" do
    before { seed_app }

    let!(:baseline) { score.to_h }

    let(:current) do
      write_file("app/views/pages/about.html.erb", %(<p>About</p>\n<img src="b.png">\n<a href="/x"></a>\n))
      write_file("app/views/pages/home.html.erb", "<p>Hi</p>\n")
      score(at: noon + 3600).to_h
    end

    it "gives the change in every total, bucket, type and file" do
      comparison = described_class.compare(current, baseline)

      expect(comparison["totals"]).to eq(
        "issues" => { "before" => 8, "after" => 7, "change" => -1 },
        "per_100_templates" => { "before" => 133.3, "after" => 116.7, "change" => -16.6 },
        "templates_scanned" => { "before" => 6, "after" => 6, "change" => 0 }
      )
      expect(comparison["buckets"]["hardcoded_values"]["count"]).to eq("before" => 3, "after" => 1, "change" => -2)
      expect(comparison["buckets"]["accessibility"]["by_type"]).to eq(
        "image_alt" => { "before" => 1, "after" => 1, "change" => 0 },
        "link_name" => { "before" => 0, "after" => 1, "change" => 1 }
      )
      expect(comparison["files"]).to eq("app/views/pages/home.html.erb" => -3, "app/views/pages/about.html.erb" => 2)
      expect(comparison["notes"]).to eq([])
    end

    it "notes a changed guardrails.yml or gem version" do
      changed = baseline.merge("config_digest" => "abc", "generator" => "ui_guardrails 2.0.0")
      expect(described_class.compare(current, changed)["notes"])
        .to eq(["guardrails.yml changed", "scored by ui_guardrails 2.0.0, now ui_guardrails #{Guardrails::VERSION}"])
    end

    it "prints the headline, the buckets and how they moved" do
      text = described_class.summary(current, described_class.compare(current, baseline))

      expect(text).to include(
        "UI drift score: 116.7 issues per 100 templates (7 issues in 6 templates)",
        "  Hardcoded values            1  stylesheet_color 1",
        "  Accessibility               2  image_alt 1, link_name 1",
        "Against 2026-10-19T12:00:00Z: 8 → 7 issues (−1), 133.3 → 116.7 per 100 templates",
        "  Hardcoded values            3 → 1 (−2)",
        "  Reinvented components       4 → 4 (0)",
        "  Most changed: app/views/pages/home.html.erb −3, app/views/pages/about.html.erb +2"
      )
    end
  end
end
