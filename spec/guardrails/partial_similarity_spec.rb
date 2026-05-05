# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/partial_similarity"

RSpec.describe Guardrails::PartialSimilarity do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_partial(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  describe "#tokenize" do
    it "extracts tag names from HTML" do
      tokens = described_class.new(root: root, output: StringIO.new).tokenize(<<~ERB)
        <div class="card">
          <h1>Title</h1>
          <p>Body</p>
        </div>
      ERB

      expect(tokens).to eq(%w[div h1 h1 p p div])
    end

    it "lowercases tag names" do
      tokens = described_class.new(root: root, output: StringIO.new).tokenize("<DIV><H1></H1></DIV>")

      expect(tokens).to eq(%w[div h1 h1 div])
    end

    it "ignores ERB blocks" do
      tokens = described_class.new(root: root, output: StringIO.new).tokenize(<<~ERB)
        <div>
          <% items.each do |i| %>
            <span><%= i.name %></span>
          <% end %>
        </div>
      ERB

      expect(tokens).to eq(%w[div span span div])
    end

    it "returns an empty list for content with no tags" do
      tokens = described_class.new(root: root, output: StringIO.new).tokenize("Just some text")
      expect(tokens).to be_empty
    end
  end

  describe "#compute_findings" do
    it "flags two structurally identical partials" do
      structure = <<~ERB
        <div class="card">
          <header><h2>Title</h2></header>
          <section><p>One</p><p>Two</p></section>
          <footer><a href="#">Link</a></footer>
        </div>
      ERB
      write_partial "app/views/users/_card.html.erb", structure
      write_partial "app/views/posts/_card.html.erb", structure

      findings = described_class.new(root: root, output: StringIO.new).compute_findings

      expect(findings.length).to eq(1)
      expect(findings.first.score).to eq(1.0)
    end

    it "flags partials with high but not perfect similarity" do
      a = <<~ERB
        <article class="card">
          <header>
            <h1>Title</h1>
            <p class="subtitle">Subtitle</p>
          </header>
          <section class="body">
            <p>Paragraph one</p>
            <p>Paragraph two</p>
            <p>Paragraph three</p>
            <ul>
              <li>One</li>
              <li>Two</li>
            </ul>
          </section>
          <footer>
            <a href="#">Link</a>
          </footer>
        </article>
      ERB
      b = <<~ERB
        <article class="card">
          <header>
            <h1>Title</h1>
            <p class="subtitle">Subtitle</p>
          </header>
          <section class="body">
            <p>Paragraph one</p>
            <p>Paragraph two</p>
            <p>Paragraph three</p>
            <ul>
              <li>One</li>
              <li>Two</li>
            </ul>
          </section>
          <footer>
            <span>note</span>
          </footer>
        </article>
      ERB
      write_partial "app/views/users/_card.html.erb", a
      write_partial "app/views/posts/_summary.html.erb", b

      findings = described_class.new(root: root, output: StringIO.new, threshold: 0.5).compute_findings

      expect(findings.length).to eq(1)
      expect(findings.first.score).to be > 0.5
      expect(findings.first.score).to be < 1.0
    end

    it "ignores partials below the threshold" do
      write_partial "app/views/users/_card.html.erb", <<~ERB
        <div><h1>X</h1><p>One</p><a>Link</a><span>S</span></div>
      ERB
      write_partial "app/views/posts/_unrelated.html.erb", <<~ERB
        <table><tr><td>A</td></tr><tr><td>B</td></tr></table>
      ERB

      findings = described_class.new(root: root, output: StringIO.new).compute_findings

      expect(findings).to be_empty
    end

    it "skips partials with too few tags to be meaningful" do
      write_partial "app/views/_tiny.html.erb", "<p>x</p>"
      write_partial "app/views/_alsotiny.html.erb", "<p>y</p>"

      findings = described_class.new(root: root, output: StringIO.new).compute_findings

      expect(findings).to be_empty
    end

    it "respects a custom threshold" do
      a = "<div><h1></h1><p></p><span></span><a></a></div>"
      b = "<section><h1></h1><p></p><span></span><a></a></section>"
      write_partial "app/views/_a.html.erb", a
      write_partial "app/views/_b.html.erb", b

      strict = described_class.new(root: root, output: StringIO.new, threshold: 0.99).compute_findings
      lax = described_class.new(root: root, output: StringIO.new, threshold: 0.3).compute_findings

      expect(strict).to be_empty
      expect(lax).not_to be_empty
    end

    it "scans both app/views and app/components" do
      structure = "<div><h1>X</h1><p>1</p><p>2</p><p>3</p></div>"
      write_partial "app/views/_a.html.erb", structure
      write_partial "app/components/_b.html.erb", structure

      findings = described_class.new(root: root, output: StringIO.new).compute_findings

      expect(findings.length).to eq(1)
    end

    it "scans ViewComponent sidecar templates (no underscore prefix)" do
      structure = "<div><h1>X</h1><p>1</p><p>2</p><p>3</p></div>"
      write_partial "app/components/user_card_component.html.erb", structure
      write_partial "app/components/admin_card_component.html.erb", structure

      findings = described_class.new(root: root, output: StringIO.new).compute_findings

      expect(findings.length).to eq(1)
    end

    it "matches VC templates against ERB partials when structurally similar" do
      structure = "<div><h1>X</h1><p>1</p><p>2</p><p>3</p></div>"
      write_partial "app/views/users/_card.html.erb", structure
      write_partial "app/components/admin_card_component.html.erb", structure

      findings = described_class.new(root: root, output: StringIO.new).compute_findings

      expect(findings.length).to eq(1)
    end

    it "reports findings sorted by score descending" do
      identical = "<div><h1>x</h1><h2>y</h2><p>z</p><p>z</p><p>z</p></div>"
      similar = "<div><h1>x</h1><h2>y</h2><p>z</p><p>z</p><span>z</span></div>"
      write_partial "app/views/_a.html.erb", identical
      write_partial "app/views/_b.html.erb", identical
      write_partial "app/views/_c.html.erb", similar

      findings = described_class.new(root: root, output: StringIO.new, threshold: 0.5).compute_findings

      scores = findings.map(&:score)
      expect(scores).to eq(scores.sort.reverse)
    end
  end

  describe "report output" do
    it "is silent when there are no findings" do
      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to eq("")
    end

    it "prints findings when there are matches" do
      structure = "<div><h1>x</h1><p>1</p><p>2</p><p>3</p></div>"
      write_partial "app/views/_a.html.erb", structure
      write_partial "app/views/_b.html.erb", structure

      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("similar pair")
      expect(output.string).to include("_a.html.erb")
      expect(output.string).to include("_b.html.erb")
    end
  end
end
