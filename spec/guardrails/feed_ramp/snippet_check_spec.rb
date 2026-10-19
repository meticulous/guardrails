# frozen_string_literal: true

require "guardrails/feed_ramp"

RSpec.describe Guardrails::FeedRamp::SnippetCheck do
  let(:fixture) { Pathname(File.expand_path("../../fixtures/feed_ramp_app", __dir__)) }
  let(:check) { described_class.new(root: fixture, manifest: Guardrails::FeedRamp::Manifest.new(root: fixture).to_h) }

  def findings(source, **options)
    check.call(source, **options)["findings"].map { |f| f.values_at("rule", "severity", "line", "message") }
  end

  it "guesses ERB or Ruby from the source" do
    expect(check.call("<p>x</p>")["language"]).to eq("erb")
    expect(check.call("div { plain 'x' }")["language"]).to eq("ruby")
    expect { check.call("x", language: "haml") }.to raise_error(ArgumentError, /erb or ruby/)
  end

  it "checks component calls in Ruby, as a Phlex view writes them" do
    source = <<~RUBY
      def view_template
        render CardComponent.new(titel: "Hi")
        render IconComponent.new
        render IconComponent.new(:x, 24, 3)
        render Admin::BadgeComponent.new(count: 2)
        render SomethingElse.new(whatever: 1)
      end
    RUBY
    expect(findings(source)).to eq([
      ["unknown_param", "error", 2, "CardComponent.new doesn't take `titel:`."],
      ["wrong_arguments", "error", 3, "IconComponent.new needs 1 positional argument, not 0."],
      ["wrong_arguments", "error", 4, "IconComponent.new takes 2 positional arguments, not 3."]
    ])
    expect(check.call(source)["findings"].first["fix"]).to eq("Did you mean `title:`? It takes (title: nil).")
  end

  it "names the nearest components for one that doesn't exist" do
    result = check.call("render ButonComponent.new(label: 'x')")["findings"].first
    expect(result).to include("rule" => "unknown_component", "message" => "ButonComponent isn't one of this app's components.")
    expect(result["fix"]).to start_with("Use one of: ButtonComponent")
  end

  it "resolves a short name when only one component has it, and skips splats" do
    expect(findings("render BadgeComponent.new(tone: :warn)").map(&:first)).to eq(["missing_param"])
    expect(findings("render ButtonComponent.new(**options)")).to eq([])
  end

  it "warns about a likely typo that a **options param would swallow" do
    expect(findings(%(render ButtonComponent.new(label: "x", varient: :danger))))
      .to eq([["unknown_param", "warning", 1, "`varient:` goes into ButtonComponent's **html_options, not a param."]])
  end

  it "reports Ruby that doesn't parse" do
    expect(findings("render ButtonComponent.new(label: ").map(&:first)).to eq(["ruby_syntax"])
  end

  it "checks ERB block renders and keeps ERB line numbers, skipping comments and control flow" do
    source = <<~ERB
      <%# render ButtonComponent.new %>
      <% if true %>
        <%= render CardComponent.new(titel: "x") do |card| %>
          <p>Body</p>
        <% end %>
      <% end %>
    ERB
    expect(findings(source)).to eq([["unknown_param", "error", 3, "CardComponent.new doesn't take `titel:`."]])
  end

  it "runs the audit and static a11y over ERB, as if it were at the given path" do
    result = check.call(%(<img src="x.png">\n<button class="btn">Go</button>\n))
    expect(result["findings"].map { |f| f["rule"] }).to eq(["a11y (static)"])
    expect(result["ok"]).to be false
    expect(result["path"]).to eq("app/views/_snippet.html.erb")
    expect(check.call("<p>x</p>", path: "./app/views/a.html.erb")["path"]).to eq("app/views/a.html.erb")
  end
end
