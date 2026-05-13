# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/cross_codebase_patterns"

RSpec.describe Guardrails::CrossCodebasePatterns do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_view(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  def run_patterns(**opts)
    described_class.new(root: root, output: StringIO.new, **opts).find_patterns
  end

  describe "#find_patterns" do
    it "returns empty when no views exist" do
      expect(run_patterns).to be_empty
    end

    it "finds a structural shape that appears 3+ times across files" do
      card = <<~ERB
        <article class="card">
          <header><h2>Title</h2></header>
          <section><p>One</p><p>Two</p></section>
          <footer><a href="#">Link</a></footer>
        </article>
      ERB
      3.times { |i| write_view "app/views/page#{i}.html.erb", card }

      patterns = run_patterns
      expect(patterns.length).to eq(1)
      expect(patterns.first.count).to eq(3)
      expect(patterns.first.size).to be >= 5
    end

    it "ignores shapes that appear fewer than min_occurrences times" do
      shape = "<div><h1>x</h1><p>1</p><p>2</p><p>3</p></div>"
      2.times { |i| write_view "app/views/page#{i}.html.erb", shape }

      expect(run_patterns).to be_empty
    end

    it "ignores subtrees smaller than min_size" do
      tiny = "<div><h1></h1></div>" # 2 elements
      3.times { |i| write_view "app/views/page#{i}.html.erb", tiny }

      expect(run_patterns).to be_empty
    end

    it "respects custom min_size" do
      tiny = "<div><h1></h1></div>"
      3.times { |i| write_view "app/views/page#{i}.html.erb", tiny }

      patterns = run_patterns(min_size: 2)
      expect(patterns.length).to eq(1)
      expect(patterns.first.size).to eq(2)
    end

    it "respects custom min_occurrences" do
      shape = "<div><h1></h1><p></p><p></p><p></p><p></p></div>"
      2.times { |i| write_view "app/views/page#{i}.html.erb", shape }

      expect(run_patterns(min_occurrences: 2).length).to eq(1)
      expect(run_patterns(min_occurrences: 3)).to be_empty
    end

    it "treats different tag structures as distinct shapes" do
      a = "<article><h1>x</h1><p>1</p><p>2</p><p>3</p></article>"
      b = "<section><h1>x</h1><p>1</p><p>2</p><p>3</p></section>"
      3.times { |i| write_view "app/views/a#{i}.html.erb", a }
      3.times { |i| write_view "app/views/b#{i}.html.erb", b }

      patterns = run_patterns
      expect(patterns.length).to eq(2)
    end

    it "ignores text content and attribute differences (structural-only)" do
      a = '<div class="primary"><h1>Hello</h1><p>One</p><p>Two</p><p>Three</p></div>'
      b = '<div class="secondary"><h1>Goodbye</h1><p>Foo</p><p>Bar</p><p>Baz</p></div>'
      write_view "app/views/a.html.erb", a
      write_view "app/views/b.html.erb", b
      write_view "app/views/c.html.erb", a

      patterns = run_patterns
      expect(patterns.length).to eq(1)
      expect(patterns.first.count).to eq(3)
    end

    it "sorts patterns by occurrence count desc, then by size desc" do
      big_rare = "<article><h1></h1><h2></h2><p></p><p></p><p></p><p></p><a></a></article>"
      small_common = "<div><h1></h1><p></p><p></p><p></p><p></p></div>"

      3.times { |i| write_view "app/views/big#{i}.html.erb", big_rare }
      5.times { |i| write_view "app/views/small#{i}.html.erb", small_common }

      patterns = run_patterns
      expect(patterns.length).to eq(2)
      expect(patterns.first.count).to eq(5) # small_common, more occurrences
      expect(patterns.last.count).to eq(3) # big_rare, fewer occurrences
    end

    it "scans both app/views and app/components" do
      shape = "<div><h1></h1><p></p><p></p><p></p><p></p></div>"
      write_view "app/views/a.html.erb", shape
      write_view "app/views/b.html.erb", shape
      write_view "app/components/c.html.erb", shape

      patterns = run_patterns
      expect(patterns.length).to eq(1)
      expect(patterns.first.count).to eq(3)
    end

    it "skips vendor / node_modules / tmp / public / log paths" do
      shape = "<div><h1></h1><p></p><p></p><p></p><p></p></div>"
      write_view "app/views/a.html.erb", shape
      write_view "app/views/b.html.erb", shape
      write_view "app/views/vendor/c.html.erb", shape
      write_view "app/views/tmp/d.html.erb", shape

      patterns = run_patterns
      # Only 2 of 4 should count — vendor and tmp ignored
      expect(patterns).to be_empty # below min_occurrences=3
    end

    it "skips mailer-style directories" do
      shape = "<div><h1></h1><p></p><p></p><p></p><p></p></div>"
      write_view "app/views/a.html.erb", shape
      write_view "app/views/b.html.erb", shape
      write_view "app/views/contact_mailer/c.html.erb", shape
      write_view "app/views/devise/mailer/d.html.erb", shape

      patterns = run_patterns
      expect(patterns).to be_empty
    end

    it "records occurrence file, line, and size" do
      shape = "<div><h1></h1><p></p><p></p><p></p><p></p></div>"
      write_view "app/views/a.html.erb", shape
      write_view "app/views/b.html.erb", "\n\n#{shape}"
      write_view "app/views/c.html.erb", shape

      pattern = run_patterns.first
      files = pattern.occurrences.map(&:file).sort
      expect(files).to eq(%w[app/views/a.html.erb app/views/b.html.erb app/views/c.html.erb])
      # b.html.erb has the shape on line 3
      b_occ = pattern.occurrences.find { |o| o.file == "app/views/b.html.erb" }
      expect(b_occ.line).to eq(3)
    end

    it "reports the outer shape only when an inner shape is fully contained by it" do
      # A "card" containing an "actions" block. The outer
      # `article(h1, div(a,a,a))` dominates the inner `div(a,a,a)` —
      # both have the same occurrence count and live in the same files,
      # so the inner is dropped as redundant. The outer is what a
      # refactor would extract; the inner is just a substring of it.
      view = <<~ERB
        <article>
          <h1></h1>
          <div class="actions"><a></a><a></a><a></a></div>
        </article>
      ERB
      4.times { |i| write_view "app/views/page#{i}.html.erb", view }

      patterns = run_patterns(min_size: 4)
      expect(patterns.map(&:size)).to eq([6]) # article + h1 + div + 3 a only
    end

    it "keeps an inner shape when it appears in more places than the outer" do
      # `div(a,a,a)` appears 6 times: 4 inside `article(...)` and 2
      # standalone. Counts differ (outer=4, inner=6), so dedupe leaves
      # both — the inner is a legitimately distinct refactor candidate.
      with_article = <<~ERB
        <article>
          <h1></h1>
          <div class="actions"><a></a><a></a><a></a></div>
        </article>
      ERB
      standalone = '<div class="actions"><a></a><a></a><a></a></div>'
      4.times { |i| write_view "app/views/card#{i}.html.erb", with_article }
      2.times { |i| write_view "app/views/stand#{i}.html.erb", standalone }

      patterns = run_patterns(min_size: 4)
      counts = patterns.map(&:count).sort
      expect(counts).to eq([4, 6])
    end

    it "doesn't dedupe two patterns that share a prefix but differ in arity" do
      # `div(a,a)` is a substring of `div(a,a,a)` starting at position 0,
      # but it's a structurally different shape (2 children vs 3) — not a
      # proper sub-shape. Both should survive dedupe.
      two_a = "<div><a></a><a></a><span></span><span></span></div>" # div(a,a,span,span), size 5
      three_a = "<div><a></a><a></a><a></a><span></span></div>"     # div(a,a,a,span),    size 5
      3.times { |i| write_view "app/views/two#{i}.html.erb", two_a }
      3.times { |i| write_view "app/views/three#{i}.html.erb", three_a }

      patterns = run_patterns
      shapes = patterns.map(&:shape).sort
      expect(shapes).to eq(["div(a,a,a,span)", "div(a,a,span,span)"])
    end

    it "doesn't false-match a sub-shape that happens to be a substring inside an unrelated tag" do
      # `tr` appears as text inside `strong` if you do a naive substring
      # search — but the shape grammar uses `(` / `,` / `)` boundaries,
      # so the contains_subshape? check shouldn't trip.
      a = "<strong><em></em><em></em><em></em><em></em></strong>"
      b = "<tr><td></td><td></td><td></td><td></td></tr>"
      3.times { |i| write_view "app/views/a#{i}.html.erb", a }
      3.times { |i| write_view "app/views/b#{i}.html.erb", b }

      patterns = run_patterns
      shapes = patterns.map(&:shape).sort
      expect(shapes).to eq(["strong(em,em,em,em)", "tr(td,td,td,td)"])
    end
  end

  describe "#run (report output)" do
    it "is silent when no patterns found" do
      output = StringIO.new
      described_class.new(root: root, output: output).run
      expect(output.string).to eq("")
    end

    it "prints a section heading, framing intro, and per-pattern detail" do
      shape = "<div><h1>x</h1><p>1</p><p>2</p><p>3</p></div>"
      3.times { |i| write_view "app/views/page#{i}.html.erb", shape }

      output = StringIO.new
      described_class.new(root: root, output: output).run

      # Section heading uses the SUGGEST severity and names what's being reported
      expect(output.string).to include("SUGGEST")
      expect(output.string).to include("cross-codebase patterns (1 candidate, 3 occurrences)")
      # Framing intro tells the reader what category catches and what action to take
      expect(output.string).to include("repeat 3+ times across your views")
      # Per-finding line is severity-tagged and carries shape + size + count
      expect(output.string).to include("[suggest]")
      expect(output.string).to include("shape: div(h1,p,p,p) (5 elements, 3 occurrences)")
      # Inline suggestion arrow with an action
      expect(output.string).to include("→")
      expect(output.string).to include("consider extracting")
      # Occurrence locations still present
      expect(output.string).to include("app/views/page0.html.erb")
    end

    it "elides occurrences past max_occurrences_shown with '… and N more'" do
      shape = "<div><h1></h1><p></p><p></p><p></p><p></p></div>"
      12.times { |i| write_view "app/views/page#{i}.html.erb", shape }

      output = StringIO.new
      described_class.new(root: root, output: output, max_occurrences_shown: 3).run

      expect(output.string).to include("… and 9 more")
    end

    it "varies the suggestion text by pattern signal" do
      # Many repetitions → 'named component' wording. A shape repeated
      # 6+ times reads as a too-common pattern to keep open-coded.
      big_repeat = "<div><h1></h1><p></p><p></p><p></p><p></p></div>"
      6.times { |i| write_view "app/views/page#{i}.html.erb", big_repeat }

      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("named component is likely the right shape")
    end
  end
end
