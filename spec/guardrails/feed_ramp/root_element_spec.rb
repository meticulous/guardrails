# frozen_string_literal: true

require "tmpdir"
require "guardrails/feed_ramp"

# The patterns are cut down from real apps' components.
RSpec.describe Guardrails::FeedRamp::RootElement do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      write_file("app/components/application_component.rb", <<~RUBY)
        class ApplicationComponent < ViewComponent::Base
          def build_css(*base_classes, extra: nil)
            [*base_classes, *Array(extra)].flatten.compact.join(" ")
          end

          def html_options(**options) = options
        end
      RUBY
      example.run
    end
  end

  def write_file(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def root_of(name)
    config = Guardrails::FeedRamp::Config.load(@root)
    discovery = Guardrails::FeedRamp::Discovery.new(root: @root, config: config)
    component = discovery.components.find { |c| c.name == name }
    described_class.for(component, @root, index: discovery.index)
  end

  it "reads the unconditional strings a class helper is given" do
    write_file("app/components/kbd_component.rb", <<~RUBY)
      class KbdComponent < ApplicationComponent
        def call
          tag.kbd @keys, class: class_names("kbd", "kbd--bare": @bare)
        end
      end
    RUBY
    expect(root_of("KbdComponent")).to eq("tag" => "kbd", "classes" => ["kbd"])
  end

  it "follows `class:` to a method, and leaves out conditional and interpolated classes" do
    write_file("app/components/meter_component.rb", <<~RUBY)
      class MeterComponent < ApplicationComponent
        def call
          tag.div(class: classes) { content }
        end

        private

        def classes = class_names("meter", ("meter--\#{tone}" if tone), "meter--\#{@size}", "meter--grayed": @grayed)
      end
    RUBY
    expect(root_of("MeterComponent")).to eq("tag" => "div", "classes" => ["meter"])
  end

  it "follows a splatted attributes method through compact and merge to its class:" do
    write_file("app/components/badge_component.rb", <<~RUBY)
      class BadgeComponent < ApplicationComponent
        private

        def css_classes
          build_css('badge', (@variant == :neutral ? nil : "badge-\#{@variant}"), extra: @extra)
        end

        def span_attributes
          { class: css_classes, data: @data, aria: @aria }.compact.merge(@html_attributes)
        end
      end
    RUBY
    write_file("app/components/badge_component.html.erb", "<%= tag.span(label_content, **span_attributes) %>\n")
    expect(root_of("BadgeComponent")).to eq("tag" => "span", "classes" => ["badge"])
  end

  it "reads `attrs[:class] =` in an attributes method, and a tag picked at runtime as any tag" do
    write_file("app/components/button_component.rb", <<~RUBY)
      class ButtonComponent < ApplicationComponent
        def initialize(label: nil, tag: :button, **options)
          @tag = tag
        end

        def call
          return button_element if form_url.nil?

          helpers.form_with(url: form_url) { button_element }
        end

        private

        def button_element
          content_tag(rendered_tag, **tag_attributes) { label }
        end

        def rendered_tag
          return :a if options[:href].present?
          tag
        end

        def tag_attributes
          attrs = options.dup
          attrs[:class] = build_css("button", ("button-\#{variant}" unless variant == :default), extra: attrs.delete(:class))
          attrs
        end
      end
    RUBY
    expect(root_of("ButtonComponent")).to eq("tag" => nil, "classes" => ["button"])
  end

  it "takes a `content_tag(@tag, …)` tag from the initialize default" do
    write_file("app/components/section_label_component.rb", <<~RUBY)
      class SectionLabelComponent < ApplicationComponent
        def initialize(text, tag: :span)
          @tag = tag
        end

        def call
          content_tag @tag, @text, class: "section-label"
        end
      end
    RUBY
    expect(root_of("SectionLabelComponent")).to eq("tag" => "span", "classes" => ["section-label"])
  end

  it "reads attributes injected into a template's open tag" do
    write_file("app/components/card_component.rb", <<~RUBY)
      class CardComponent < ApplicationComponent
        private

        def wrapper_attributes
          @html_attributes.merge(class: build_css("article-card", "article-card--\#{@variant}", extra: @html_attributes[:class]))
        end
      end
    RUBY
    write_file("app/components/card_component.html.erb", <<~ERB)
      <article <%= tag.attributes(**wrapper_attributes) %>>
        <header class="article-card__header"><%= title %></header>
      </article>
    ERB
    expect(root_of("CardComponent")).to eq("tag" => "article", "classes" => ["article-card"])
  end

  it "reads a template that opens with a tag helper block, and a class from an ERB fragment" do
    write_file("app/components/meter_component.rb", <<~RUBY)
      class MeterComponent < ApplicationComponent
        def classes = class_names("meter", "meter--coverage": @coverage)
      end
    RUBY
    write_file("app/components/meter_component.html.erb", <<~ERB)
      <%= tag.div class: classes do %>
        <p class="meter__header"><%= @label %></p>
      <% end %>
    ERB
    write_file("app/components/stat_component.rb", <<~RUBY)
      class StatComponent < ApplicationComponent
        STAT = "stat stat--plain"
      end
    RUBY
    write_file("app/components/stat_component.html.erb", %(<p class="<%= STAT %> wide"><%= @value %></p>\n))

    expect(root_of("MeterComponent")).to eq("tag" => "div", "classes" => ["meter"])
    expect(root_of("StatComponent")).to eq("tag" => "p", "classes" => %w[stat stat--plain wide])
  end

  it "maps Rails tag helpers to the element they build, and follows a helper given the classes" do
    write_file("app/components/text_input_component.rb", <<~RUBY)
      class TextInputComponent < ApplicationComponent
        def call
          text_field_tag @name, @value, **@options, class: class_names("input", @options[:class])
        end
      end
    RUBY
    write_file("app/components/tabs_component.rb", <<~RUBY)
      class TabsComponent < ApplicationComponent
        def attributes = html_options(class: "tabs", aria: { label: @label })
      end
    RUBY
    write_file("app/components/tabs_component.html.erb", "<%= tag.nav(**attributes) do %><%= content %><% end %>\n")

    expect(root_of("TextInputComponent")).to eq("tag" => "input", "classes" => ["input"])
    expect(root_of("TabsComponent")).to eq("tag" => "nav", "classes" => ["tabs"])
  end

  it "doesn't take a method named like a tag for the tag" do
    write_file("app/components/link_component.rb", <<~RUBY)
      class LinkComponent < ApplicationComponent
        def call
          tag.a(body, href: @href, class: "link")
        end

        def body = @label
      end
    RUBY
    expect(root_of("LinkComponent")).to eq("tag" => "a", "classes" => ["link"])
  end

  it "has no classes when they all depend on arguments, and no root when the template opens with other output" do
    write_file("app/components/tooltip_component.rb", <<~RUBY)
      class TooltipComponent < ApplicationComponent
        def initialize(text, wrapper_class:, tag: :span) = nil
      end
    RUBY
    write_file("app/components/tooltip_component.html.erb", "<%= content_tag @tag, class: @wrapper_class do %><%= content %><% end %>\n")
    write_file("app/components/panel_component.rb", "class PanelComponent < ApplicationComponent\nend\n")
    write_file("app/components/panel_component.html.erb", %(<%= render CardComponent.new %>\n<div class="panel"></div>\n))

    expect(root_of("TooltipComponent")).to eq("tag" => "span", "classes" => [])
    expect(root_of("PanelComponent")).to be_nil
  end
end
