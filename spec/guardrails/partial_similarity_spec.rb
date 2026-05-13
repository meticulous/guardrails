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

  describe "#group_findings" do
    let(:audit) { described_class.new(root: root, output: StringIO.new) }

    def finding(a, b, score: 1.0)
      Guardrails::PartialSimilarity::Finding.new(
        file_a: a, file_b: b, score: score, tag_count_a: 6, tag_count_b: 6
      )
    end

    it "collapses a clique of N pairwise-similar files into one group" do
      # 4 files all pairwise similar = C(4,2) = 6 pairs, should collapse to 1 group
      pairs = [
        finding("a.html.erb", "b.html.erb"),
        finding("a.html.erb", "c.html.erb"),
        finding("a.html.erb", "d.html.erb"),
        finding("b.html.erb", "c.html.erb"),
        finding("b.html.erb", "d.html.erb"),
        finding("c.html.erb", "d.html.erb")
      ]

      groups = audit.group_findings(pairs)
      expect(groups.length).to eq(1)
      expect(groups.first[:files]).to eq(%w[a.html.erb b.html.erb c.html.erb d.html.erb])
      expect(groups.first[:pair_count]).to eq(6)
    end

    it "keeps unrelated pairs separate" do
      pairs = [
        finding("a.html.erb", "b.html.erb"),
        finding("c.html.erb", "d.html.erb")
      ]

      groups = audit.group_findings(pairs)
      expect(groups.length).to eq(2)
      expect(groups.map { |g| g[:files] }).to contain_exactly(
        %w[a.html.erb b.html.erb],
        %w[c.html.erb d.html.erb]
      )
    end

    it "captures score range within a mixed-score component" do
      pairs = [
        finding("a.html.erb", "b.html.erb", score: 1.0),
        finding("a.html.erb", "c.html.erb", score: 0.85),
        finding("b.html.erb", "c.html.erb", score: 0.92)
      ]

      groups = audit.group_findings(pairs)
      expect(groups.first[:score_min]).to eq(0.85)
      expect(groups.first[:score_max]).to eq(1.0)
    end

    it "sorts groups by size (largest first)" do
      pairs = [
        finding("a.html.erb", "b.html.erb"),
        finding("c.html.erb", "d.html.erb"),
        finding("c.html.erb", "e.html.erb"),
        finding("d.html.erb", "e.html.erb")
      ]

      groups = audit.group_findings(pairs)
      expect(groups.first[:files].length).to eq(3)
      expect(groups.last[:files].length).to eq(2)
    end

    it "exposes a sample_pair Finding for downstream rendering" do
      pair = finding("a.html.erb", "b.html.erb")
      groups = audit.group_findings([pair])

      expect(groups.first[:sample_pair]).to eq(pair)
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

      # Severity tag + section heading
      expect(output.string).to include("SUGGEST")
      expect(output.string).to include("similar partials")
      # Framing intro names the action
      expect(output.string).to include("Likely duplicates")
      # Per-pair tagged line + suggestion arrow
      expect(output.string).to include("[suggest]")
      expect(output.string).to include("→")
      expect(output.string).to include("_a.html.erb")
      expect(output.string).to include("_b.html.erb")
    end

    it "prints a 'group of N' line when many partials are pairwise similar" do
      structure = "<div><h1>x</h1><p>1</p><p>2</p><p>3</p></div>"
      4.times { |i| write_partial "app/views/_t#{i}.html.erb", structure }

      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("group of 4 similar templates")
      expect(output.string).to include("6 pairs") # C(4,2)
    end

    it "preserves tag-count info for size-2 (single-pair) groups" do
      structure_a = "<div><h1>x</h1><p>1</p><p>2</p><p>3</p></div>"
      structure_b = "<div><h1>x</h1><p>1</p><p>2</p><p>3</p></div>"
      write_partial "app/views/_a.html.erb", structure_a
      write_partial "app/views/_b.html.erb", structure_b

      output = StringIO.new
      described_class.new(root: root, output: output).run

      # Pair header carries both file names; tag-count line follows it
      expect(output.string).to match(/_a\.html\.erb ↔ .+_b\.html\.erb/)
      expect(output.string).to match(/\d+ \/ \d+ tags/)
    end
  end
end
