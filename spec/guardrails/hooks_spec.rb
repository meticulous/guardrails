# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "guardrails/hooks"

RSpec.describe Guardrails::Hooks do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  def write(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def git(*args)
    _out, err, status = Open3.capture3("git", "-c", "user.email=t@example.com", "-c", "user.name=T", *args, chdir: @root.to_s)
    raise err unless status.success?
  end

  def commit_all
    git("init", "-q") unless @root.join(".git").exist?
    git("add", ".")
    git("commit", "-qm", "snapshot")
  end

  def event(kind, files: [], continued: false)
    Guardrails::Hooks::Event.new(kind: kind, root: @root, files: files, continued: continued)
  end

  describe Guardrails::Hooks::Drift do
    subject(:drift) { described_class.new(root: @root) }

    it "reports only what's new since HEAD, matching findings that moved lines" do
      write("app/views/pages/a.html.erb", %(<div style="color: red">Old</div>\n))
      commit_all
      write("app/views/pages/a.html.erb", %(<p>Intro</p>\n<div style="color: red">Old</div>\n<img src="x.png">\n))

      items = drift.introduced(["app/views/pages/a.html.erb"])

      expect(items.map(&:category)).to eq(["a11y (static)"])
      expect(items.first).to have_attributes(file: "app/views/pages/a.html.erb", line: 3, severity: :error)
      expect(items.first.to_s).to include("app/views/pages/a.html.erb:3 image_alt")
    end

    it "counts repeats: a second copy of an existing finding is new" do
      write("app/views/pages/a.html.erb", %(<div style="color: red">x</div>\n))
      commit_all
      write("app/views/pages/a.html.erb", %(<div style="color: red">x</div>\n<div style="color: red">x</div>\n))

      expect(drift.introduced(["app/views/pages/a.html.erb"]).map(&:line)).to eq([2])
    end

    it "treats every finding in an untracked file as new and lists changed templates" do
      write("app/views/pages/a.html.erb", "<p>ok</p>\n")
      commit_all
      write("app/views/pages/b.html.erb", "<button></button>\n")
      write("app/models/thing.rb", "class Thing; end\n")

      expect(drift.changed_files).to eq(["app/views/pages/b.html.erb"])
      expect(drift.introduced(drift.changed_files).map(&:title)).to eq(["button_name: <button></button>"])
    end

    it "ignores files outside the scan paths, ignored ones, and ones outside the app" do
      write("guardrails.yml", "guardrails:\n  audit:\n    ignore:\n      - app/views/legacy\n")
      write("app/views/legacy/old.html.erb", %(<div style="color: red"></div>\n))
      write("lib/templates/x.html.erb", %(<div style="color: red"></div>\n))

      expect(drift.introduced(["app/views/legacy/old.html.erb", "lib/templates/x.html.erb", "/etc/hosts"])).to eq([])
    end

    it "works outside a git repository, treating everything as new" do
      write("app/views/pages/a.html.erb", "<img src=\"x.png\">\n")

      expect(drift.changed_files).to eq([])
      expect(drift.introduced(["app/views/pages/a.html.erb"]).size).to eq(1)
    end
  end

  describe ".check" do
    before do
      write("app/views/pages/a.html.erb", "<p>ok</p>\n")
      commit_all
    end

    it "tells the agent about drift right after an edit, without blocking" do
      write("app/views/pages/a.html.erb", %(<p style="margin: 4px">ok</p>\n))

      outcome = described_class.check(event(:edit, files: [@root.join("app/views/pages/a.html.erb").to_s]))

      expect(outcome.block).to be false
      expect(outcome.message).to include("drift you just introduced", "[warning] app/views/pages/a.html.erb:1 inline_style")
    end

    it "reports markup that copies a component as a warning, without refusing the stop" do
      write("app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\nend\n")
      write("app/components/button_component.html.erb", %(<button class="button" aria-label="<%= @label %>"></button>\n))
      require "guardrails/feed_ramp"
      Guardrails::FeedRamp::Manifest.new(root: @root).write
      write("app/views/pages/a.html.erb", %(<button class="button">Save</button>\n))

      outcome = described_class.check(event(:edit, files: ["app/views/pages/a.html.erb"]))
      expect(outcome.message).to include("[warning] app/views/pages/a.html.erb:1 component_match", "render ButtonComponent")
      expect(described_class.check(event(:stop)).block).to be false
    end

    it "refuses to stop on a new error, once, and lets warnings through" do
      write("app/views/pages/a.html.erb", %(<p style="margin: 4px">ok</p>\n))
      expect(described_class.check(event(:stop)).block).to be false

      write("app/views/pages/a.html.erb", %(<p style="margin: 4px">ok</p>\n<img src="x.png">\n))
      outcome = described_class.check(event(:stop))
      expect(outcome.block).to be true
      expect(outcome.message).to include("[error] app/views/pages/a.html.erb:2 image_alt", "[warning]")

      expect(described_class.check(event(:stop, continued: true)).block).to be false
    end

    it "adds what registered contributors say" do
      contributor = Object.new
      def contributor.on_stop(_event) = Guardrails::Hooks::Outcome.new(notes: ["A reviewer rejected /pricing."], block: true)
      def contributor.on_session_start(_event) = Guardrails::Hooks::Outcome.new(notes: ["1 open rejection."], block: false)
      described_class.register(:review, contributor)

      expect(described_class.check(event(:stop))).to have_attributes(block: true, notes: ["A reviewer rejected /pricing."])
      expect(described_class.check(event(:session_start)).notes).to eq(["1 open rejection."])
      expect(described_class.check(event(:edit, files: ["app/views/pages/a.html.erb"])).notes).to eq([])
    ensure
      described_class.unregister(:review)
    end

    it "points a new session at the Feed Ramp component list when there is one" do
      expect(described_class.check(event(:session_start)).notes).to eq([])

      write(".ui_guardrails/COMPONENTS.md", "# Components\n")
      write(".ui_guardrails/manifest.json", %({"components": [{"name": "ButtonComponent"}, {"name": "CardComponent"}]}))
      expect(described_class.check(event(:session_start)).message)
        .to eq("This app's 2 UI components and design tokens are listed in .ui_guardrails/COMPONENTS.md, " \
               "each with its params and a real usage example. Render one of them instead of writing the markup by hand.")

      write(".ui_guardrails/manifest.json", "not json")
      expect(described_class.check(event(:session_start)).message).to start_with("This app's UI components and design tokens")
    end

    it "finds the component list in a configured output_dir" do
      write("guardrails.yml", "guardrails:\n  feed_ramp:\n    output_dir: docs/ui\n")
      write("docs/ui/COMPONENTS.md", "# Components\n")
      expect(described_class.check(event(:session_start)).message).to include("listed in docs/ui/COMPONENTS.md")
    end

    it "skips a contributor that raises and keeps everything else" do
      write("app/views/pages/a.html.erb", %(<img src="x.png">\n))
      broken = Object.new
      def broken.on_stop(_event) = raise(LoadError, "cannot load such file -- vips")
      described_class.register(:broken, broken)

      outcome = nil
      expect { outcome = described_class.check(event(:stop)) }.to output(/broken: LoadError: cannot load such file -- vips/).to_stderr
      expect(outcome.block).to be true
      expect(outcome.message).to include("image_alt")
    ensure
      described_class.unregister(:broken)
    end
  end
end
