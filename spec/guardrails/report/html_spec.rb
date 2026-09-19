# frozen_string_literal: true

require "tmpdir"
require "guardrails/report/run"
require "guardrails/report/html"

RSpec.describe Guardrails::Report::Html do
  let(:root) { Pathname(File.expand_path("../../../examples/demo", __dir__)) }
  let(:categories) { Guardrails::Report::Run.new(root: root).call.categories }
  let(:html) { described_class.new(categories: categories, root: root, generated_at: Time.new(2026, 9, 19, 14, 30)).render }

  it "is one self-contained document — no external requests" do
    expect(html).to start_with("<!doctype html>")
    expect(html).not_to match(/<link[^>]+href=|<script[^>]+src=|<img[^>]+src=|@import|url\(/)
  end

  it "rolls findings up by severity with links into each category" do
    expect(html).to include("Errors — 8 findings", "Warnings — 10 findings", "Suggestions — 2 findings")
    expect(html).to include('<a href="#cat-raw-color">raw_color</a>', 'id="cat-raw-color"')
    expect(html).to include('id="cat-a11y-static"')
  end

  it "renders every finding with its suggestion, location, and framing" do
    expect(html.scan('<article class="finding').length).to eq(20)
    expect(html).to include("replace with var(--primary-500)")
    expect(html).to include("app/views/welcome/broken.html.erb:7:12")
    expect(html).to include("Hex/rgb literals in color attributes bypass your design tokens.")
  end

  it "stamps the project, time, and gem version" do
    expect(html).to include("Guardrails audit — demo", "2026-09-19 14:30", "ui_guardrails #{Guardrails::VERSION}")
  end

  it "credits Meticulous in the footer" do
    expect(html).to include('built by <a href="https://meticulous.com" rel="noopener">Meticulous</a> with love')
  end

  it "carries absolute paths and positions for editor links" do
    expect(html).to include(%(data-path="#{root.join('app/views/welcome/broken.html.erb')}" data-line="7" data-column="12"))
  end

  it "escapes everything that came from the audited project" do
    expect(html).to include("&lt;svg fill=&quot;#0066ff&quot;")
    expect(html).not_to include('<svg fill="#0066ff"')
  end

  it "stays inert when a finding carries markup or script" do
    hostile = Guardrails::Report::Finding.new(
      category: "inline_style", severity: :warning, title: %(<script>alert(1)</script>),
      suggestion: %("><img src=x onerror=alert(2)>), snippet: "</pre></code><script>alert(3)</script>",
      locations: [Guardrails::Report::Location.new(file: %(app/views/"><script>alert(4)</script>.erb), line: 1)],
      details: [["class", "</dd><script>alert(5)</script>"]]
    )
    category = Guardrails::Report::Category.new(name: "<b>inline_style</b>", severity: :warning,
                                                framing: "<script>alert(6)</script>", findings: [hostile])
    page = described_class.new(categories: [category], root: root).render

    expect(page.scan(/<script/).length).to eq(1) # the report's own
    expect(page).not_to match(/<img|<b>inline/)
  end

  it "collapses long location lists" do
    locations = (1..20).map { |n| Guardrails::Report::Location.new(file: "app/views/p#{n}.html.erb", line: n) }
    finding = Guardrails::Report::Finding.new(category: "class-itis", severity: :suggestion, title: "<div>", locations: locations)
    category = Guardrails::Report::Category.new(name: "class-itis", severity: :suggestion, findings: [finding])
    page = described_class.new(categories: [category], root: root).render

    expect(page).to include("… and 12 more")
    expect(page.scan('class="loc"').length).to eq(20)
  end

  it "renders a clean audit" do
    page = described_class.new(categories: [], root: root).render

    expect(page).to include("No findings — the audit is clean.")
    expect(page).not_to include("<table")
  end

  describe "#write" do
    it "writes under the project root by default, creating directories" do
      Dir.mktmpdir do |dir|
        path = described_class.new(categories: categories, root: dir).write

        expect(path.to_s).to eq(File.join(File.realpath(dir), "tmp/guardrails/audit.html")).or eq(File.join(dir, "tmp/guardrails/audit.html"))
        expect(File.read(path)).to include("<!doctype html>")
      end
    end

    it "honors an absolute path" do
      Dir.mktmpdir do |dir|
        target = File.join(dir, "out/report.html")

        expect(described_class.new(categories: [], root: root).write(target).to_s).to eq(target)
        expect(File).to exist(target)
      end
    end
  end
end
