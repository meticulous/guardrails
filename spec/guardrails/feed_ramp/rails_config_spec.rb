# frozen_string_literal: true

require "tmpdir"
require "guardrails/feed_ramp"

RSpec.describe Guardrails::FeedRamp::RailsConfig do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  def write_file(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  it "reads preview paths however the app's config adds them" do
    write_file("config/application.rb", <<~RUBY)
      module Shop
        class Application < Rails::Application
          config.view_component.previews.paths << Rails.root.join("spec/components/previews").to_s
          config.view_component.previews.default_layout = "component_preview"
          config.view_component.preview_paths += ["\#{Rails.root}/lib/component_previews"]
          config.lookbook.preview_paths = [root.join("app", "previews"), File.expand_path("../design/previews", __dir__)]
        end
      end
    RUBY
    write_file("config/environments/development.rb", <<~RUBY)
      Rails.application.configure do
        config.view_component.previews.paths.concat(["test/previews", Rails.root.join("spec/components/previews")])
      end
    RUBY

    expect(described_class.preview_paths(@root))
      .to eq(%w[spec/components/previews lib/component_previews app/previews design/previews test/previews])
  end

  it "leaves out paths computed at boot or outside the app" do
    write_file("config/application.rb", <<~RUBY)
      config.view_component.previews.paths << ENV.fetch("PREVIEWS")
      config.lookbook.preview_paths = ["/opt/shared/previews", Rails.root.join("../engine/previews")]
      config.view_component.default_preview_layout = "preview"
    RUBY
    expect(described_class.preview_paths(@root)).to eq([])
  end

  it "is empty without a Rails config" do
    expect(described_class.preview_paths(@root)).to eq([])
  end

  it "feeds discovery, so previews outside the default paths are found" do
    write_file("app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\n  def call; end\nend\n")
    write_file("design/previews/button_component_preview.rb", <<~RUBY)
      class ButtonComponentPreview < ViewComponent::Preview
        def default
          render(ButtonComponent.new)
        end
      end
    RUBY
    manifest = -> { Guardrails::FeedRamp::Manifest.new(root: @root).to_h["components"].first }
    expect(manifest.call["example"]).to be_nil

    write_file("config/application.rb", %(config.lookbook.preview_paths = [Rails.root.join("design/previews")]\n))
    expect(manifest.call["example"]).to include("source" => "render(ButtonComponent.new)", "from" => "preview")
  end
end
