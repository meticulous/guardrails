# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/class_itis"

RSpec.describe Guardrails::ClassItis do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_view(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  def run_clusters(**opts)
    described_class.new(root: root, output: StringIO.new, **opts).find_clusters
  end

  describe "#find_clusters" do
    it "returns empty when no views exist" do
      expect(run_clusters).to be_empty
    end

    it "groups identical (tag, class-list) tuples that repeat 3+ times" do
      button = '<button class="px-4 py-2 text-sm font-medium bg-white">Save</button>'
      3.times { |i| write_view "app/views/page#{i}.html.erb", button }

      clusters = run_clusters
      expect(clusters.length).to eq(1)
      expect(clusters.first.tag).to eq("button")
      expect(clusters.first.count).to eq(3)
      expect(clusters.first.classes).to eq(%w[bg-white font-medium px-4 py-2 text-sm])
    end

    it "ignores class lists below the min_classes threshold" do
      button = '<button class="btn primary">Save</button>'
      3.times { |i| write_view "app/views/page#{i}.html.erb", button }

      expect(run_clusters).to be_empty
    end

    it "ignores tuples that appear fewer than min_occurrences times" do
      button = '<button class="px-4 py-2 text-sm font-medium bg-white">Save</button>'
      2.times { |i| write_view "app/views/page#{i}.html.erb", button }

      expect(run_clusters).to be_empty
    end

    it "respects custom min_classes" do
      el = '<button class="a b c">x</button>'
      3.times { |i| write_view "app/views/page#{i}.html.erb", el }

      expect(run_clusters(min_classes: 3).length).to eq(1)
      expect(run_clusters(min_classes: 4)).to be_empty
    end

    it "respects custom min_occurrences" do
      el = '<button class="a b c d e">x</button>'
      2.times { |i| write_view "app/views/page#{i}.html.erb", el }

      expect(run_clusters(min_occurrences: 2).length).to eq(1)
      expect(run_clusters(min_occurrences: 3)).to be_empty
    end

    it "treats different tags as distinct clusters even with identical class lists" do
      button = '<button class="px-4 py-2 text-sm font-medium bg-white">x</button>'
      anchor = '<a class="px-4 py-2 text-sm font-medium bg-white">x</a>'
      3.times { |i| write_view "app/views/b#{i}.html.erb", button }
      3.times { |i| write_view "app/views/a#{i}.html.erb", anchor }

      tags = run_clusters.map(&:tag).sort
      expect(tags).to eq(%w[a button])
    end

    it "treats different class orderings as the same cluster" do
      a = '<button class="px-4 py-2 text-sm font-medium bg-white">x</button>'
      b = '<button class="bg-white text-sm py-2 font-medium px-4">x</button>'
      write_view "app/views/a.html.erb", a
      write_view "app/views/b.html.erb", b
      write_view "app/views/c.html.erb", a

      clusters = run_clusters
      expect(clusters.length).to eq(1)
      expect(clusters.first.count).to eq(3)
    end

    it "deduplicates within a single class attribute (no inflated counts from repeats)" do
      # Pathological but real — `class="px-4 px-4 py-2 ..."` shouldn't count as 6 distinct classes
      el = '<button class="px-4 px-4 px-4 py-2">x</button>'
      3.times { |i| write_view "app/views/page#{i}.html.erb", el }

      expect(run_clusters).to be_empty # only 2 unique classes after dedup
    end

    it "skips elements whose class attribute is fully ERB-driven" do
      # No static text in the class — we can't fingerprint dynamic class names
      el = '<button class="<%= computed_classes %>">x</button>'
      3.times { |i| write_view "app/views/page#{i}.html.erb", el }

      expect(run_clusters).to be_empty
    end

    it "uses only the static portion when ERB and literals mix" do
      # The `<%= ... %>` part is dropped; static classes still count
      el = '<button class="px-4 py-2 text-sm font-medium bg-white <%= variant %>">x</button>'
      3.times { |i| write_view "app/views/page#{i}.html.erb", el }

      cluster = run_clusters.first
      expect(cluster).not_to be_nil
      expect(cluster.classes).to eq(%w[bg-white font-medium px-4 py-2 text-sm])
    end

    it "scans both app/views and app/components" do
      el = '<button class="a b c d e">x</button>'
      write_view "app/views/a.html.erb", el
      write_view "app/views/b.html.erb", el
      write_view "app/components/c.html.erb", el

      cluster = run_clusters.first
      expect(cluster.count).to eq(3)
    end

    it "skips vendor / node_modules / tmp / public / log paths" do
      el = '<button class="a b c d e">x</button>'
      write_view "app/views/a.html.erb", el
      write_view "app/views/b.html.erb", el
      write_view "app/views/vendor/c.html.erb", el
      write_view "app/views/tmp/d.html.erb", el

      expect(run_clusters).to be_empty # only 2 of 4 count
    end

    it "skips mailer-style directories" do
      el = '<button class="a b c d e">x</button>'
      write_view "app/views/a.html.erb", el
      write_view "app/views/b.html.erb", el
      write_view "app/views/contact_mailer/c.html.erb", el
      write_view "app/views/devise/mailer/d.html.erb", el

      expect(run_clusters).to be_empty
    end

    it "sorts clusters by occurrence count desc, then class count desc" do
      big_rare = '<button class="a b c d e f g h">x</button>'
      small_common = '<a class="p q r s t">x</a>'
      3.times { |i| write_view "app/views/big#{i}.html.erb", big_rare }
      5.times { |i| write_view "app/views/small#{i}.html.erb", small_common }

      clusters = run_clusters
      expect(clusters.first.count).to eq(5) # small_common first, more occurrences
      expect(clusters.last.count).to eq(3)
    end

    it "records occurrence file, line, and column" do
      el = '<button class="a b c d e">x</button>'
      write_view "app/views/a.html.erb", el
      write_view "app/views/b.html.erb", "\n\n#{el}"
      write_view "app/views/c.html.erb", el

      cluster = run_clusters.first
      b_occ = cluster.occurrences.find { |o| o.file == "app/views/b.html.erb" }
      expect(b_occ.line).to eq(3)
      expect(b_occ.column).to eq(1)
    end

    it "handles elements with no class attribute" do
      bare = "<button>Save</button>"
      classy = '<button class="a b c d e">Save</button>'
      3.times { |i| write_view "app/views/bare#{i}.html.erb", bare }
      3.times { |i| write_view "app/views/classy#{i}.html.erb", classy }

      clusters = run_clusters
      expect(clusters.length).to eq(1)
      expect(clusters.first.classes).to eq(%w[a b c d e])
    end
  end

  describe "#run (report output)" do
    it "is silent when no clusters found" do
      output = StringIO.new
      described_class.new(root: root, output: output).run
      expect(output.string).to eq("")
    end

    it "prints a section heading, framing intro, and per-cluster detail" do
      el = '<button class="px-4 py-2 text-sm font-medium bg-white">x</button>'
      3.times { |i| write_view "app/views/page#{i}.html.erb", el }

      output = StringIO.new
      described_class.new(root: root, output: output).run

      # Severity + category in the heading
      expect(output.string).to include("SUGGEST")
      expect(output.string).to include("class-itis (1 cluster, 3 occurrences)")
      # Framing intro names the problem + the action
      expect(output.string).to include("classic AI-paste pattern")
      # Per-cluster tagged line + suggestion + class list + locations
      expect(output.string).to include("[suggest]")
      expect(output.string).to include("<button> with 5 classes, 3 occurrences")
      expect(output.string).to include("→")
      expect(output.string).to include("class=\"bg-white font-medium px-4 py-2 text-sm\"")
      expect(output.string).to include("app/views/page0.html.erb")
    end

    it "elides occurrences past max_occurrences_shown with '… and N more'" do
      el = '<button class="a b c d e">x</button>'
      12.times { |i| write_view "app/views/page#{i}.html.erb", el }

      output = StringIO.new
      described_class.new(root: root, output: output, max_occurrences_shown: 3).run

      expect(output.string).to include("… and 9 more")
    end

    it "truncates very long class strings in the display" do
      classes = (1..40).map { |i| "cls#{i}" }.join(" ")
      el = "<button class=\"#{classes}\">x</button>"
      3.times { |i| write_view "app/views/page#{i}.html.erb", el }

      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("...")
    end
  end
end
