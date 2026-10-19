# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "guardrails/feed_ramp"

RSpec.describe Guardrails::FeedRamp::Manifest do
  let(:fixture) { Pathname(File.expand_path("../../fixtures/feed_ramp_app", __dir__)) }

  describe "on an app with ViewComponent, Phlex and Lookbook" do
    let(:manifest) { described_class.new(root: fixture).to_h }
    let(:components) { manifest["components"].to_h { |c| [c["name"], c] } }

    it "reads the libraries from Gemfile.lock" do
      expect(manifest["libraries"]).to eq(
        "lookbook" => "2.3.4", "phlex" => "1.11.0", "phlex-rails" => "1.2.2", "view_component" => "3.21.0"
      )
    end

    it "lists ViewComponent and Phlex components, through the app's own base classes, sorted" do
      expect(components.keys).to eq(%w[Admin::BadgeComponent ButtonComponent CardComponent Components::Alert
                                       IconComponent TooltipComponent])
      expect(components.transform_values { |c| c["kind"] }).to include(
        "ButtonComponent" => "view_component", "Components::Alert" => "phlex"
      )
    end

    it "leaves out base classes that render nothing and plain Ruby classes" do
      expect(components.keys).not_to include("ApplicationComponent", "Components::Base", "NotAComponent")
    end

    it "records where each component lives" do
      expect(components["ButtonComponent"]).to include(
        "file" => "app/components/button_component.rb", "line" => 7,
        "template" => "app/components/button_component.html.erb", "superclass" => "ApplicationComponent"
      )
      expect(components["Admin::BadgeComponent"]).to include("template" => nil, "superclass" => "ApplicationComponent")
      expect(components["Components::Alert"]["superclass"]).to eq("Components::Base")
    end

    it "records each component's root element: its tag and the classes it always has" do
      expect(components.transform_values { |c| c["root_element"] }).to eq(
        "Admin::BadgeComponent" => { "tag" => "span", "classes" => ["badge"] },  # tag.span in `call`
        "ButtonComponent" => { "tag" => "button", "classes" => ["btn"] },       # not `btn--<%= @variant %>`
        "CardComponent" => { "tag" => "section", "classes" => ["card"] },
        "Components::Alert" => { "tag" => "div", "classes" => ["alert"] },      # not `alert--#{@tone}`
        "IconComponent" => nil,
        "TooltipComponent" => { "tag" => "span", "classes" => [] }
      )
    end

    it "captures constructor params with defaults, and YARD @param docs" do
      expect(components["ButtonComponent"]["params"]).to eq([
        { "name" => "label", "kind" => "keyword", "required" => true, "default" => nil,
          "type" => "String", "description" => "the visible text" },
        { "name" => "variant", "kind" => "keyword", "required" => false, "default" => ":primary",
          "type" => "Symbol", "description" => ":primary, :secondary or :danger" },
        { "name" => "size", "kind" => "keyword", "required" => false, "default" => ":md",
          "type" => nil, "description" => nil },
        { "name" => "html_options", "kind" => "keyrest", "required" => false, "default" => nil,
          "type" => nil, "description" => nil }
      ])
      expect(components["IconComponent"]["params"].map { |p| p.values_at("name", "kind", "required", "default") })
        .to eq([["name", "positional", true, nil], ["size", "positional", false, "16"]])
    end

    it "takes the description from the doc comment, without YARD tags" do
      expect(components["ButtonComponent"]["description"])
        .to eq("The app's button. Use it for every clickable action that isn't a link.")
      expect(components["IconComponent"]["description"]).to be_nil
    end

    it "captures ViewComponent slots: component, string, lambda and polymorphic" do
      slots = components["CardComponent"]["slots"].to_h { |s| [s["name"], s] }

      expect(slots["actions"]).to include("kind" => "renders_many", "type" => "ButtonComponent")
      expect(slots["header"]).to include("kind" => "renders_one", "type" => "lambda")
      expect(slots["header"]["params"].map { |p| p.values_at("name", "required", "default") })
        .to eq([["title", true, nil], ["level", false, "2"]])
      expect(slots["visual"]).to include("type" => "polymorphic", "types" => %w[icon image])
      expect(components["ButtonComponent"]["slots"].first).to include("name" => "icon", "type" => "IconComponent")
    end

    it "lists a Phlex component's public block-taking methods as heuristic slots" do
      expect(components["Components::Alert"]["slots"]).to eq([
        { "name" => "title", "kind" => "block_method", "type" => nil, "heuristic" => true,
          "params" => [{ "name" => "text", "kind" => "positional", "required" => false, "default" => "nil" }] }
      ])
    end

    it "turns preview methods into variants, with Lookbook annotations" do
      previews = components["ButtonComponent"]["previews"]

      expect(previews.map { |p| p["name"] }).to eq(%w[default danger x])
      expect(previews[0]).to include("label" => "Primary button", "hidden" => false,
                                     "file" => "test/components/previews/button_component_preview.rb", "line" => 5)
      expect(previews[1]).to include("description" => "A destructive action.")
      expect(previews[1]["params"].first).to include("name" => "label", "default" => "\"Delete\"")
      expect(previews[2]["hidden"]).to be true
    end

    it "matches previews by name, by namespace, and by what they render" do
      expect(components["Admin::BadgeComponent"]["previews"].map { |p| p["name"] }).to eq(["warning"])
      expect(components["Components::Alert"]["previews"].map { |p| p["file"] })
        .to eq(["spec/components/previews/alert_preview.rb"])
      expect(components["CardComponent"]["previews"]).to be_empty
    end

    it "copies the shortest visible preview render as the example" do
      expect(components["ButtonComponent"]["example"]).to eq(
        "source" => %(render(ButtonComponent.new(label: "Save"))),
        "file" => "test/components/previews/button_component_preview.rb", "line" => 6,
        "from" => "preview", "language" => "ruby"
      )
    end

    it "prefers a usage that names the component in full over one inside its namespace" do
      # The preview says `BadgeComponent.new` inside `module Admin`; the view's
      # `Admin::BadgeComponent` works anywhere.
      expect(components["Admin::BadgeComponent"]["example"]).to include(
        "source" => "<%= render Admin::BadgeComponent.new(count: 3) %>", "from" => "call_site", "language" => "erb",
        "file" => "app/views/pages/home.html.erb", "line" => 6
      )
    end

    it "falls back to a real call site, a block render copied through its end tag" do
      expect(components["CardComponent"]["example"]["source"]).to eq(<<~ERB.chomp)
        <%= render CardComponent.new(title: "Welcome") do |card| %>
          <% card.with_header(title: "Hello") %>
          <p>Body</p>
        <% end %>
      ERB
    end

    it "finds call sites in Ruby views" do
      manifest_without_preview = described_class.new(
        root: fixture, config: Guardrails::FeedRamp::Config.new(preview_paths: [])
      ).to_h
      alert = manifest_without_preview["components"].find { |c| c["name"] == "Components::Alert" }

      expect(alert["example"]).to include("file" => "app/views/pages/show_view.rb", "line" => 7, "language" => "ruby")
      expect(alert["example"]["source"]).to eq(%(render Components::Alert.new(tone: :warning) do |alert|\n  alert.title("Heads up")\nend))
    end

    it "never makes up an example for a component nothing renders" do
      expect(components["TooltipComponent"]["example"]).to be_nil
      expect(components["IconComponent"]["example"]).to be_nil
    end

    it "collects tokens from :root and @theme blocks, the first definition by file path winning" do
      tokens = manifest["tokens"].to_h { |t| [t["name"], t] }

      expect(tokens.keys).to eq(%w[--color-brand --radius-card --shadow-card --spacing-gutter --surface --text-body])
      expect(tokens["--spacing-gutter"]).to include("value" => "1.5rem", "category" => "spacing",
                                                    "file" => "app/assets/tailwind/application.css", "line" => 5)
      # Defined in both stylesheets; app/assets/stylesheets/ sorts first.
      expect(tokens["--color-brand"]).to include("value" => "#000000", "category" => "color")
      expect(tokens["--text-body"]["category"]).to eq("typography")
    end

    it "ignores custom properties outside :root / @theme, and commented-out ones" do
      expect(manifest["tokens"].map { |t| t["name"] }).not_to include("--local-only", "--commented-out")
    end
  end

  describe "without the component libraries" do
    let(:root) { Pathname(Dir.mktmpdir) }
    after { FileUtils.rm_rf(root) }

    def write(relative, content = "")
      path = root.join(relative)
      path.dirname.mkpath
      path.write(content)
    end

    it "builds an empty manifest for an app with nothing to find" do
      manifest = described_class.new(root: root).to_h

      expect(manifest["libraries"].values).to all(be_nil)
      expect(manifest["components"]).to eq([])
      expect(manifest["tokens"]).to eq([])
    end

    it "still finds components from their superclasses when there's no Gemfile.lock" do
      write "app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\n  def call; end\nend\n"

      expect(described_class.new(root: root).to_h["components"].map { |c| c["name"] }).to eq(["ButtonComponent"])
    end

    it "skips files that don't parse cleanly without failing" do
      write "app/components/broken_component.rb", "class BrokenComponent < ViewComponent::Base\n  def call(\nend\n"
      write "app/components/ok_component.rb", "class OkComponent < ViewComponent::Base\n  def call; end\nend\n"

      expect { described_class.new(root: root).to_h }.not_to raise_error
    end

    it "reads extra token files and component paths from guardrails.yml" do
      write "guardrails.yml", <<~YAML
        guardrails:
          feed_ramp:
            component_paths: [app/ui]
            token_files: [design/spacing.css]
      YAML
      write "design/spacing.css", "--space-1: 4px;\n--space-2: 8px;\n"
      write "app/ui/pill.rb", "class Pill < Phlex::HTML\n  def view_template; end\nend\n"

      manifest = described_class.new(root: root).to_h
      expect(manifest["components"].map { |c| c["name"] }).to eq(["Pill"])
      expect(manifest["tokens"].map { |t| [t["name"], t["category"]] }).to eq([%w[--space-1 spacing], %w[--space-2 spacing]])
    end
  end

  describe "writing" do
    let(:root) { Pathname(Dir.mktmpdir) }
    after { FileUtils.rm_rf(root) }

    before { FileUtils.cp_r("#{fixture}/.", root) }

    it "writes manifest.json and COMPONENTS.md under .ui_guardrails" do
      statuses = described_class.new(root: root).write

      expect(statuses.transform_keys { |path| path.relative_path_from(root).to_s })
        .to eq(".ui_guardrails/manifest.json" => :created, ".ui_guardrails/COMPONENTS.md" => :created)
      expect(JSON.parse(root.join(".ui_guardrails/manifest.json").read)["schema_version"]).to eq(1)
    end

    it "is deterministic: a second run leaves both files byte-identical" do
      described_class.new(root: root).write
      first = [root.join(".ui_guardrails/manifest.json").read, root.join(".ui_guardrails/COMPONENTS.md").read]

      expect(described_class.new(root: root).write.values).to eq(%i[unchanged unchanged])
      expect([root.join(".ui_guardrails/manifest.json").read, root.join(".ui_guardrails/COMPONENTS.md").read]).to eq(first)
    end

    it "is stale until written, and again once a component changes" do
      expect(described_class.new(root: root)).to be_stale

      described_class.new(root: root).write
      expect(described_class.new(root: root)).not_to be_stale

      root.join("app/components/tooltip_component.rb").write("class TooltipComponent < ViewComponent::Base\nend\n")
      expect(described_class.new(root: root)).to be_stale
    end

    it "goes stale when a view starts rendering a component" do
      described_class.new(root: root).write
      root.join("app/views/pages/about.html.erb").write("<%= render TooltipComponent.new(text: \"Hi\") %>\n")

      expect(described_class.new(root: root)).to be_stale
    end

    it "stays fresh when a view changes without changing the manifest" do
      described_class.new(root: root).write
      root.join("app/views/pages/home.html.erb").write(root.join("app/views/pages/home.html.erb").read + "<p>More copy</p>\n")
      root.join("README.md").write("unrelated")

      expect(described_class.new(root: root)).not_to be_stale
    end

    it "is stale when a written file was edited by hand" do
      described_class.new(root: root).write
      root.join(".ui_guardrails/COMPONENTS.md").write("hand edit")

      expect(described_class.new(root: root)).to be_stale
    end
  end

  describe "COMPONENTS.md" do
    let(:markdown) { described_class.new(root: fixture).markdown }

    it "documents each component with its signature, slots, previews and example" do
      expect(markdown).to include(
        "## ButtonComponent",
        "`app/components/button_component.rb` · `app/components/button_component.html.erb` · ViewComponent",
        "- `label:` (required) [String] — the visible text",
        "- `variant: :primary` [Symbol]",
        "- `**html_options`",
        "- `icon` (renders_one) → `IconComponent`",
        "**Previews**: default (Primary button), danger",
        "**Example** (from `test/components/previews/button_component_preview.rb:6`)\n\n```ruby\nrender(ButtonComponent.new(label: \"Save\"))\n```"
      )
    end

    it "says so when a component has no example, rather than inventing one" do
      expect(markdown).to include("## TooltipComponent").and include("**Example**: no usage found in previews or views.")
    end

    it "marks Phlex block methods as a heuristic and lists tokens" do
      expect(markdown).to include("**Slots** (methods that take a block)", "| `--spacing-gutter` | `1.5rem` | spacing |")
    end
  end
end
