# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/icons"
require "guardrails/icons/emoji_scan"

RSpec.describe Guardrails::Icons::EmojiScan do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  def scan(**opts)
    described_class.new(root: root, output: StringIO.new, **opts).call
  end

  describe "classifier" do
    subject(:scanner) { described_class.new(root: root, output: StringIO.new) }

    # This is the whole reason \p{Emoji} is banned as the primary
    # test — it matches ASCII digits, `#`, `*`.
    it "does not classify digits, #, or * as emoji or glyphs" do
      %w[0 1 5 9 # *].each do |c|
        expect(scanner.classify(c)).to be_nil, "expected #{c.inspect} to classify as nil"
      end
    end

    it "does not classify letters, punctuation, quotes, dashes, or ellipsis as icons" do
      %w[a Z . , ; " ' … – —].each do |c|
        expect(scanner.classify(c)).to be_nil, "expected #{c.inspect} to classify as nil"
      end
    end

    it "classifies standard pictographs as emoji" do
      # 📄 doc, 📦 package, 🔑 key, 👤 person
      expect(scanner.classify("\u{1F4C4}")).to eq(:emoji)
      expect(scanner.classify("\u{1F4E6}")).to eq(:emoji)
      expect(scanner.classify("\u{1F511}")).to eq(:emoji)
      expect(scanner.classify("\u{1F464}")).to eq(:emoji)
    end

    it "classifies VS16-styled pictographs as emoji (one cluster)" do
      # 📽️ = 1F4FD + FE0F
      cluster = "\u{1F4FD}\u{FE0F}"
      expect(cluster.grapheme_clusters.length).to eq(1) # sanity
      expect(scanner.classify(cluster)).to eq(:emoji)
    end

    it "classifies ZWJ sequences as emoji (one cluster)" do
      # 👨‍👩‍👧 family = man + ZWJ + woman + ZWJ + girl
      cluster = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
      expect(cluster.grapheme_clusters.length).to eq(1)
      expect(scanner.classify(cluster)).to eq(:emoji)
    end

    it "classifies regional-indicator pairs (flags) as emoji" do
      # 🇺🇸 US flag = 1F1FA + 1F1F8
      cluster = "\u{1F1FA}\u{1F1F8}"
      expect(cluster.grapheme_clusters.length).to eq(1)
      # Explicit belt-and-braces: neither codepoint carries
      # Extended_Pictographic — this is why the classifier has a
      # separate regional-indicator predicate.
      expect("\u{1F1FA}".match?(/\p{Extended_Pictographic}/)).to be false
      expect(scanner.classify(cluster)).to eq(:emoji)
    end

    it "classifies keycap sequences as emoji" do
      # 1️⃣ keycap = 31 + FE0F + 20E3
      keycap = "1\u{FE0F}\u{20E3}"
      expect(keycap.grapheme_clusters.length).to eq(1)
      expect(scanner.classify(keycap)).to eq(:emoji)

      # #️⃣ and *️⃣ variants
      expect(scanner.classify("#\u{FE0F}\u{20E3}")).to eq(:emoji)
      expect(scanner.classify("*\u{FE0F}\u{20E3}")).to eq(:emoji)
    end

    it "classifies plain check-marks, arrows, geometric shapes as glyphs (not emoji)" do
      # ✓ (U+2713), ✕ (U+2715), → (U+2192), ● (U+25CF), ★ (U+2605), ☆ (U+2606)
      %w[✓ ✕ → ● ★ ☆].each do |c|
        expect(scanner.classify(c)).to eq(:glyph), "expected #{c.inspect} to classify as :glyph"
      end
    end

    it "classifies characters that are BOTH pictographic AND in a glyph range as glyphs (range-first)" do
      # ⚠ (U+26A0) is in Misc Symbols range AND Extended_Pictographic.
      # ✏ (U+270F) is in Dingbats range AND Extended_Pictographic.
      # Spec groups these under the glyph tier. Range-first
      # classification matches user intent: a team that accepts `→` in
      # prose under `glyphs: false` also accepts `⚠` / `✏` / `★`.
      expect(scanner.classify("\u{26A0}")).to eq(:glyph)
      expect(scanner.classify("\u{270F}")).to eq(:glyph)
      expect(scanner.classify("\u{2605}")).to eq(:glyph) # ★ — also Ext_Pict
    end

    it "excludes ©, ®, ™ from both tiers even though they carry Extended_Pictographic" do
      # These ship in body copy as legal notation, not iconography.
      # Explicit skip so `Foo® Inc.` doesn't false-flag.
      %w[© ® ™].each do |c|
        expect(scanner.classify(c)).to be_nil, "expected #{c.inspect} to classify as nil"
      end
    end

    it "returns nil for glyphs when glyphs: false" do
      opt_out = described_class.new(root: root, output: StringIO.new, glyphs: false)
      expect(opt_out.classify("\u{2192}")).to be_nil # → arrow
      expect(opt_out.classify("\u{2713}")).to be_nil # ✓ check
      # But real emoji still flag.
      expect(opt_out.classify("\u{1F4C4}")).to eq(:emoji)
    end

    it "respects allow_chars for specific codepoints teams accept" do
      # Team accepts → in prose but not ← .
      allowed = described_class.new(root: root, output: StringIO.new,
                                    allow_chars: ["\u{2192}"])
      expect(allowed.classify("\u{2192}")).to be_nil
      expect(allowed.classify("\u{2190}")).to eq(:glyph)
    end
  end

  describe "#call — file scanning" do
    it "flags an emoji in an ERB text node" do
      write "app/views/empty_state.html.erb", %(<div>\n  Nothing here \u{1F4E6}\n</div>\n)

      violations = scan
      expect(violations.length).to eq(1)
      v = violations.first
      expect(v.type).to eq(:emoji_icon)
      expect(v.file).to eq("app/views/empty_state.html.erb")
      expect(v.line).to eq(2)
      expect(v.snippet).to eq("\u{1F4E6}")
      expect(v.tier).to eq(:emoji)
      expect(v.codepoints).to eq("U+1F4E6")
    end

    it "flags an emoji inside <%= %> ERB output (not a comment — must still scan)" do
      write "app/views/x.html.erb", %(<%= "\u{1F4C4}" %>)

      expect(scan.length).to eq(1)
      expect(scan.first.tier).to eq(:emoji)
    end

    it "flags an emoji in a Ruby helper case branch" do
      write "app/helpers/icon_helper.rb", <<~RUBY
        module IconHelper
          def content_type_glyph(type)
            case type
            when :document then "\u{1F4C4}"
            when :package  then "\u{1F4E6}"
            end
          end
        end
      RUBY

      violations = scan
      expect(violations.length).to eq(2)
      expect(violations.map(&:tier).uniq).to eq([:emoji])
      expect(violations.map(&:line).sort).to eq([4, 5])
    end

    it "flags emoji in a Ruby constant array" do
      write "app/models/change.rb", <<~RUBY
        class Change
          GLYPHS = { edit: "\u{270F}\u{FE0F}", delete: "\u{1F5D1}" }.freeze
        end
      RUBY

      # ✏️ (VS16) + 🗑
      expect(scan.length).to eq(2)
    end

    it "allow_files skips scanning a file entirely (chat reactions constant, emoji pickers)" do
      write "app/models/reaction.rb", <<~RUBY
        class Reaction
          QUICK_REACTIONS = %w[\u{1F44D} \u{1F44E} \u{2764}].freeze
        end
      RUBY

      expect(scan.length).to eq(3)
      expect(scan(allow_files: ["app/models/reaction.rb"])).to be_empty
    end

    it "flags emoji in JS textContent assignments" do
      write "app/javascript/controllers/toggle_controller.js", <<~JS
        import { Controller } from "@hotwired/stimulus"
        export default class extends Controller {
          toggle() {
            this.element.textContent = this.isOn ? "\u{2713}" : "\u{2717}"
          }
        }
      JS

      violations = scan
      expect(violations.length).to eq(2)
      expect(violations.map(&:tier).uniq).to eq([:glyph]) # ✓ and ✗ are dingbats
    end

    it "flags emoji in YAML locale values" do
      write "config/locales/en.yml", <<~YAML
        en:
          empty_states:
            no_files: "No files yet \u{1F4C4}"
      YAML

      expect(scan.length).to eq(1)
      expect(scan.first.file).to eq("config/locales/en.yml")
    end

    it "counts VS16-styled pictograph as ONE violation, not two" do
      # \u{1F4FD}\u{FE0F} = 📽️ = one grapheme, two codepoints
      write "app/views/x.html.erb", "\u{1F4FD}\u{FE0F}"

      expect(scan.length).to eq(1)
      expect(scan.first.codepoints).to eq("U+1F4FD U+FE0F")
    end

    it "counts ZWJ family sequence as ONE violation" do
      write "app/views/x.html.erb", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

      expect(scan.length).to eq(1)
    end

    it "counts a regional-indicator flag pair as ONE violation" do
      write "app/views/x.html.erb", "\u{1F1FA}\u{1F1F8}"

      expect(scan.length).to eq(1)
    end

    it "counts a keycap sequence as ONE violation" do
      write "app/views/x.html.erb", "1\u{FE0F}\u{20E3}"

      expect(scan.length).to eq(1)
    end
  end

  describe "#call — comment masking (negative fixtures)" do
    it "does NOT flag emoji in a Ruby # comment" do
      write "app/helpers/foo.rb", <<~RUBY
        # \u{26A0}\u{FE0F} do not run in batch
        module Foo; end
      RUBY

      expect(scan).to be_empty
    end

    it "does NOT flag emoji in an ERB <%# %> comment" do
      write "app/views/x.html.erb", "<%# TODO: \u{1F4C4} extract to component %>"

      expect(scan).to be_empty
    end

    it "does NOT flag emoji in a JS // line comment" do
      write "app/javascript/x.js", "// legend: \u{2713} good, \u{2717} bad\nconst x = 1;\n"

      expect(scan).to be_empty
    end

    it "does NOT flag emoji in a JS /* */ block comment" do
      write "app/javascript/x.js", "/* Old approach: \u{1F5D1} needs review */\nfoo();\n"

      expect(scan).to be_empty
    end

    it "does NOT flag emoji in a SCSS // comment" do
      write "app/javascript/tokens.scss", "// legend: \u{2713}\n.foo { color: red; }\n"

      expect(scan).to be_empty
    end

    it "does NOT flag emoji in a YAML # comment" do
      write "config/locales/en.yml", <<~YAML
        # \u{1F4C4} used to seed empty-state copy
        en:
          hi: "hello"
      YAML

      expect(scan).to be_empty
    end

    it "still flags real string content when comments in the SAME file contain emoji" do
      # Prove masking doesn't over-suppress: the real string on line 4
      # must still be reported despite the # comment on line 1.
      write "app/helpers/x.rb", <<~RUBY
        # \u{1F4C4} legend goes here
        module X
          def a
            "\u{1F4E6}"
          end
        end
      RUBY

      violations = scan
      expect(violations.length).to eq(1)
      expect(violations.first.line).to eq(4)
    end

    it "masks Ruby comments correctly after preceding multibyte content" do
      # Byte-vs-char offset regression. Prism's default location
      # offsets are BYTE offsets; if we index the char array with
      # them, the mask starts N characters late when N bytes of
      # multibyte content precede the comment. Real-world case: a
      # string literal with an intentional emoji on the same line as
      # a comment mentioning a different emoji.
      #
      # Line 1: A = "📄"  # 📦 in comment
      # The literal 📄 (col 6) should flag; the 📦 inside `#` comment
      # should NOT flag. With byte offsets the mask starts 3 chars
      # late (📄 is 4 bytes = 4 chars in offset space but 1 char in
      # position space) and 📦 survives → false positive.
      write "app/helpers/x.rb", %(A = "\u{1F4C4}"  # \u{1F4E6} in comment\n)

      violations = scan
      expect(violations.length).to eq(1)
      expect(violations.first.snippet).to eq("\u{1F4C4}")
      expect(violations.first.line).to eq(1)
      # 📄 sits inside the quoted literal — column 6 (A=1, space=2,
      # ==3, space=4, "=5, 📄=6).
      expect(violations.first.column).to eq(6)
    end

    it "does NOT match \\p{Emoji} traps in comment-masked source (digits, #, *)" do
      write "app/models/x.rb", <<~RUBY
        class X
          COUNT = 5
          HASH = "#"
          STAR = "*"
        end
      RUBY

      expect(scan).to be_empty
    end
  end

  describe "#call — inline suppression marker" do
    it "suppresses when marker is on the SAME line (Ruby)" do
      write "app/helpers/x.rb", <<~RUBY
        module X
          BAD = "\u{1F4C4}" # guardrails-ok: emoji intentional
        end
      RUBY

      expect(scan).to be_empty
    end

    it "suppresses when marker is on the PRECEDING line (Ruby)" do
      write "app/helpers/x.rb", <<~RUBY
        module X
          # guardrails-ok: emoji shipping this consciously
          BAD = "\u{1F4C4}"
        end
      RUBY

      expect(scan).to be_empty
    end

    it "suppresses only the marked line, not the next non-adjacent finding" do
      write "app/helpers/x.rb", <<~RUBY
        module X
          A = "\u{1F4C4}" # guardrails-ok: emoji
          B = "hi"
          C = "\u{1F4E6}"
        end
      RUBY

      violations = scan
      expect(violations.length).to eq(1)
      expect(violations.first.line).to eq(4)
    end

    it "supports marker in an ERB <%# %> comment" do
      write "app/views/x.html.erb", <<~ERB
        <%# guardrails-ok: emoji legend below %>
        <p>\u{2713} good  \u{2717} bad</p>
      ERB

      expect(scan).to be_empty
    end

    it "does NOT extend a trailing-marker's suppression to the next line" do
      # A same-line marker suppresses only its own line. The next
      # line — even a legitimate finding — must still surface.
      # Silent under-reporting on a linter is the bad failure mode:
      # someone adds a marker to justify one existing emoji and
      # accidentally hides the next one they add next week.
      write "app/helpers/x.rb", <<~RUBY
        module X
          A = "\u{1F4C4}" # guardrails-ok: emoji intentional
          B = "\u{1F4E6}"
        end
      RUBY

      violations = scan
      expect(violations.length).to eq(1)
      expect(violations.first.line).to eq(3)
      expect(violations.first.snippet).to eq("\u{1F4E6}")
    end
  end

  describe "#call — line/column accuracy" do
    it "reports the exact 1-indexed char column of the grapheme" do
      # "  Hi 📄" — emoji sits at char position 6 (1: space, 2: space,
      # 3: H, 4: i, 5: space, 6: 📄).
      write "app/views/x.html.erb", "  Hi \u{1F4C4}\n"

      v = scan.first
      expect(v.line).to eq(1)
      expect(v.column).to eq(6)
    end

    it "keeps line numbers accurate across masked multi-line comments" do
      # 6-line file. Emoji sits on line 6. A block comment consumes
      # lines 1-3 (mask must preserve line breaks or line numbers
      # shift).
      write "app/javascript/x.js", <<~JS
        /*
         * multi-line
         * with \u{1F4C4} in the comment
         */
        // 5th line
        const x = "\u{2713}"
      JS

      violations = scan
      expect(violations.length).to eq(1)
      expect(violations.first.line).to eq(6)
    end
  end

  describe "#call — scan paths + ignores" do
    it "skips spec/ by default even when reachable via `app/` — no test/preview flagging" do
      # A `spec/views/foo.html.erb` isn't in the default scan set, but
      # any path with a `spec` segment is also implicitly ignored to
      # be safe for teams with non-standard layouts.
      write "spec/factories/foo.rb", %(FactoryBot.define do; factory(:x) { name "\u{1F4C4}" }; end)
      write "test/fixtures/x.yml", "one:\n  name: \"\u{1F4C4}\"\n"
      write "app/components/previews/foo_preview.rb", %(class Preview; def default; "\u{1F4C4}"; end; end)

      expect(scan).to be_empty
    end

    it "skips vendor / node_modules / tmp / public / log" do
      write "vendor/foo.rb", "# vendor\n\"\u{1F4C4}\"\n"
      write "node_modules/x.js", "const x = \"\u{2713}\";\n"

      expect(scan).to be_empty
    end

    it "honors scan_paths override" do
      write "lib/tasks/x.rake", %(task :x do puts "\u{1F4C4}" end)
      # Default doesn't cover lib/tasks — no flag.
      expect(scan).to be_empty
      # Explicit override does.
      expect(scan(scan_paths: ["lib/**/*.rake"]).length).to eq(1)
    end

    it "is a no-op when enabled: false" do
      write "app/views/x.html.erb", "\u{1F4C4}"
      expect(scan(enabled: false)).to be_empty
    end
  end
end
