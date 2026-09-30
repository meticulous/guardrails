# frozen_string_literal: true

require "pathname"
require "prism"
require "set"

module Guardrails
  class Icons
    # Emoji and dingbat-glyph detection.
    #
    # Two tiers, both on by default:
    #
    #   emoji  — anything in \p{Extended_Pictographic}, plus regional-
    #            indicator pairs (flags, U+1F1E6..U+1F1FF), plus keycap
    #            sequences ([0-9#*]️?⃣). Handles VS16 (U+FE0F)
    #            and ZWJ (U+200D) so a family sequence or VS16-styled
    #            pictograph is reported as one grapheme with the full
    #            cluster in `snippet`.
    #
    #   glyph  — Unicode symbols used as icons that are NOT emoji:
    #            Dingbats (U+2700..27BF), Miscellaneous Symbols
    #            (U+2600..26FF), Miscellaneous Technical (U+2300..23FF),
    #            Arrows (U+2190..21FF), Geometric Shapes
    #            (U+25A0..25FF), Misc Symbols & Arrows (U+2B00..2BFF).
    #
    # These render inconsistently across platforms and are what the
    # sprite exists to replace. Some teams accept `→` in prose, so the
    # glyph tier is independently configurable via
    # `guardrails.icons.emoji.glyphs`.
    #
    # `\p{Emoji}` matches ASCII digits, `#`, and `*` — never use it as
    # the primary test. Iterate grapheme clusters instead, classify
    # each with the three-way predicate below, and everything ASCII,
    # `©®™`, `…`, `–—`, currency, typographic quotes stays unflagged.
    #
    # Classification order is emoji-first, glyph-second, because
    # characters like `⚠` (U+26A0) and `✏` (U+270F) fall in the glyph
    # codepoint ranges but ALSO in Extended_Pictographic. Reporting
    # them as `emoji` matches user intuition (they're colored on all
    # modern OSes) and keeps `glyphs: false` semantics honest.
    class EmojiScan
      Violation = Struct.new(:type, :file, :line, :column, :snippet, :codepoints, :tier,
                             keyword_init: true)

      # Default file globs. Reuse Icons::USAGE_SCAN_PATTERNS shape but
      # extend to helpers/models/presenters and locales — where the
      # motivating consumer bug lived. `spec/` and `test/` are excluded
      # by convention (they're outside `app/`).
      DEFAULT_SCAN_PATTERNS = [
        "app/views/**/*.html.erb",
        "app/components/**/*.{html.erb,rb}",
        "app/helpers/**/*.rb",
        "app/models/**/*.rb",
        "app/presenters/**/*.rb",
        "app/javascript/**/*.{js,ts,jsx,tsx}",
        "config/locales/**/*.yml"
      ].freeze

      # Path components we always skip, matching the ignore list other
      # detectors use. `previews` covers Lookbook / ViewComponent
      # preview directories under both `app/` and outside it.
      IMPLICIT_IGNORE_SEGMENTS = %w[vendor node_modules tmp public log spec test previews].freeze

      # Regional-indicator range for flag sequences (pairs of these
      # form a grapheme cluster that renders as a flag).
      REGIONAL_INDICATOR = /\A[\u{1F1E6}-\u{1F1FF}]{2}\z/

      # Keycap sequence: a base character (digit, hash, or asterisk)
      # optionally followed by VS16, then the combining enclosing
      # keycap U+20E3.
      KEYCAP = /\A[0-9#*]\u{FE0F}?\u{20E3}\z/

      # Glyph-tier codepoint ranges. The spec groups characters by
      # visual family (dingbat, arrow, geometric shape) — many of these
      # ALSO carry the Extended_Pictographic property under Unicode
      # (⚠ U+26A0, ✏ U+270F, ★ U+2605), but the spec's grouping is
      # what maps to user intent: a team that accepts `→` in prose
      # under `glyphs: false` will also accept `★`. So a single
      # codepoint in one of these ranges wins glyph classification
      # regardless of Extended_Pictographic — see `classify_single`.
      #
      # Multi-codepoint clusters (VS16, ZWJ, flag, keycap) never enter
      # this branch; they're always emoji.
      GLYPH_RANGES = [
        (0x2190..0x21FF), # Arrows
        (0x2300..0x23FF), # Misc Technical
        (0x25A0..0x25FF), # Geometric Shapes
        (0x2600..0x26FF), # Misc Symbols
        (0x2700..0x27BF), # Dingbats
        (0x2B00..0x2BFF)  # Misc Symbols and Arrows
      ].freeze

      # Single codepoints Unicode marks Extended_Pictographic but are
      # never icons in practice — trademark/registered/copyright marks
      # ship in body copy as legal notation. Explicit skip so
      # `Foo® Inc` doesn't report as `emoji`.
      TYPOGRAPHIC_SKIP = Set[0x00A9, 0x00AE, 0x2122].freeze

      # Same-line or preceding-line marker that silences the finding
      # on that line. Reason text after `emoji` is optional but
      # encouraged; only the presence of the marker is required.
      INLINE_MARKER = /guardrails-ok:\s*emoji\b/

      # `output:` is accepted for symmetry with other detectors but
      # ignored — EmojiScan is pure return-a-value; the human-readable
      # report belongs to Icons#report_emoji, which owns the output
      # stream and the Style.
      def initialize(root:, output: nil, # rubocop:disable Lint/UnusedMethodArgument
                     enabled: true, glyphs: true,
                     scan_paths: nil, allow_files: nil, allow_chars: nil)
        @root = Pathname(root)
        @enabled = enabled
        @glyphs = glyphs
        @scan_paths = Array(scan_paths).compact.map(&:to_s)
        @allow_files = normalize_allow_files(allow_files)
        @allow_chars = Array(allow_chars).flat_map { |c| c.to_s.grapheme_clusters }.to_set
      end

      def call
        return [] unless @enabled

        scan_files.flat_map { |file| scan_file(file) }
      end

      # Public for testing — the classifier is the load-bearing bit.
      #
      # Returns :emoji, :glyph, or nil. Grapheme clusters that are
      # allowlisted, ASCII, punctuation, currency, `©®™`, etc. return
      # nil.
      #
      # Multi-codepoint clusters (VS16, ZWJ, flag, keycap) are always
      # emoji. Single codepoints check GLYPH_RANGES first (spec's
      # visual grouping), then fall through to Extended_Pictographic.
      def classify(grapheme)
        return nil if grapheme.nil? || grapheme.empty?
        return nil if @allow_chars.include?(grapheme)

        chars = grapheme.each_char.to_a
        if chars.length > 1
          return :emoji if multi_codepoint_emoji?(grapheme)
          return nil
        end

        classify_single(chars.first.ord)
      end

      private

      def multi_codepoint_emoji?(grapheme)
        return true if grapheme.match?(REGIONAL_INDICATOR)
        return true if grapheme.match?(KEYCAP)

        # ZWJ sequences and VS16-styled pictographs anchor on at least
        # one Extended_Pictographic codepoint (a specific pictograph);
        # the connecting ZWJ / selector pieces don't match on their own
        # but the base does.
        grapheme.each_char.any? { |c| c.match?(/\p{Extended_Pictographic}/) }
      end

      def classify_single(cp)
        return nil if TYPOGRAPHIC_SKIP.include?(cp)

        # Range-first: a codepoint in a glyph range is a glyph even if
        # Unicode marks it Extended_Pictographic. This matches the
        # spec's visual grouping and keeps `glyphs: false` predictable
        # for teams that accept small monochrome symbols in prose.
        if GLYPH_RANGES.any? { |r| r.cover?(cp) }
          return @glyphs ? :glyph : nil
        end

        return :emoji if [cp].pack("U*").match?(/\p{Extended_Pictographic}/)

        nil
      end

      def scan_files
        patterns = @scan_paths.empty? ? DEFAULT_SCAN_PATTERNS : @scan_paths
        patterns
          .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
          .map { |path| Pathname(path) }
          .uniq
          .reject { |path| ignored?(path) }
          .reject { |path| allow_listed?(path) }
      end

      def ignored?(path)
        segments = relative(path).split("/")
        (IMPLICIT_IGNORE_SEGMENTS & segments).any?
      end

      def allow_listed?(path)
        @allow_files.include?(relative(path))
      end

      def scan_file(file)
        raw = read(file)
        return [] if raw.nil? || raw.empty?

        masked = mask_comments(raw, file)
        suppressed_lines = suppressed_line_set(raw, masked)
        relative_path = relative(file)

        violations = []
        masked.each_line.with_index(1) do |line, line_num|
          next if suppressed_lines.include?(line_num)

          scan_line(line).each do |(grapheme, tier, column)|
            violations << Violation.new(
              type: :emoji_icon,
              file: relative_path,
              line: line_num,
              column: column,
              snippet: grapheme,
              codepoints: grapheme.each_char.map { |c| format("U+%04X", c.ord) }.join(" "),
              tier: tier
            )
          end
        end
        violations
      end

      # Walk the line by grapheme cluster, tracking char offset so
      # `column` is the 1-indexed character position — not byte
      # position (would be wrong for any multibyte char) and not
      # grapheme index (a family sequence spans 5 characters but
      # counts as one grapheme, and the column of the NEXT thing
      # after it needs to be char-accurate).
      def scan_line(line)
        results = []
        char_offset = 0
        line.each_grapheme_cluster do |g|
          tier = classify(g)
          results << [g, tier, char_offset + 1] if tier
          char_offset += g.length
        end
        results
      end

      # Length-preserving comment mask per file type. Non-empty return
      # value preserves line numbers and columns for accurate location
      # reporting — mirrors the strategy `mask_erb` uses in Icons.
      def mask_comments(source, file)
        ext = file.extname.downcase
        case ext
        when ".rb" then mask_ruby_comments(source)
        when ".erb" then mask_erb_comments(source)
        when ".js", ".ts", ".jsx", ".tsx", ".scss", ".sass", ".css"
          mask_js_style_comments(source)
        when ".yml", ".yaml" then mask_yaml_comments(source)
        else source
        end
      end

      # Prism ships with Ruby 3.4 (min supported). Its `comments` list
      # is more accurate than any regex: it correctly ignores `#` inside
      # string literals, interpolation, and heredocs. A regex on `#.*$`
      # would false-mask `"#icon-check"` and break inline markers.
      #
      # NB: Prism's default `start_offset` / `end_offset` are BYTE
      # offsets; indexing an array of characters with them misaligns
      # after any multibyte content earlier in the file (an emoji-in-
      # a-string followed by a `#` comment would leave the `#` region
      # unmasked and the following line partly masked). Use the
      # `_character_offset` accessors (Prism 1.5+, bundled with Ruby
      # 3.4 as a default gem) which count characters and work with
      # `String#[]=` on the source.
      def mask_ruby_comments(source)
        result = Prism.parse(source)
        chars = source.chars
        result.comments.each do |c|
          start_off = c.location.start_character_offset
          end_off = c.location.end_character_offset
          # Replace with spaces, but keep newlines so line numbers hold.
          (start_off...end_off).each do |i|
            chars[i] = " " unless chars[i] == "\n"
          end
        end
        chars.join
      rescue StandardError
        # If Prism fails on malformed source, leave uncommented — we'd
        # rather over-report than skip a real emoji hidden by a parse
        # error.
        source
      end

      # Only `<%# ... %>` in ERB is a comment. `<% ... %>` and
      # `<%= ... %>` execute Ruby that may legitimately contain
      # emoji as string literals — those must remain scannable.
      ERB_COMMENT = /<%#[\s\S]*?%>/
      def mask_erb_comments(source)
        source.gsub(ERB_COMMENT) { |m| preserve_newlines(m) }
      end

      JS_LINE_COMMENT = %r{//[^\n]*}
      JS_BLOCK_COMMENT = %r{/\*[\s\S]*?\*/}
      # Note: string-embedded `//` (e.g. inside a URL literal) will
      # false-mask through this regex. Documented gap; a full JS parser
      # would fix it but the false-negative surface is small — a URL
      # `"http://foo/📄"` would incorrectly not report. Acceptable
      # tradeoff for zero-dep scanning; add a marker if it hurts.
      def mask_js_style_comments(source)
        source
          .gsub(JS_BLOCK_COMMENT) { |m| preserve_newlines(m) }
          .gsub(JS_LINE_COMMENT) { |m| " " * m.length }
      end

      # YAML: `#` starts a comment to end-of-line, except inside quoted
      # strings. Approximated with a simpler regex: mask `#` at start
      # of line or after whitespace. Quoted `#` (rare in locale files
      # for icons) will false-mask; document if it becomes a problem.
      YAML_COMMENT = /(^|\s)#[^\n]*/
      def mask_yaml_comments(source)
        source.gsub(YAML_COMMENT) do |m|
          # Preserve the leading whitespace/anchor character.
          prefix = m.start_with?("#") ? "" : m[0]
          "#{prefix}#{" " * (m.length - prefix.length)}"
        end
      end

      def preserve_newlines(str)
        newline_count = str.count("\n")
        "\n" * newline_count + " " * (str.length - newline_count)
      end

      # Build a set of line numbers to suppress based on inline
      # markers. A marker suppresses the line it appears on. It ALSO
      # suppresses the following line only when the marker line has no
      # non-comment content — that's the "marker on the preceding
      # line" case. A trailing marker (`FOO = "\u{1F4C4}" # guardrails-ok:
      # emoji`) suppresses only its own line, so a legitimate finding
      # on the next line still surfaces.
      #
      # `raw` carries the marker text (comments are erased in `masked`);
      # `masked` tells us whether the marker line was a pure comment
      # (its `strip.empty?` in the masked form) or a trailing comment
      # after code (non-empty).
      def suppressed_line_set(raw, masked)
        suppressed = Set.new
        masked_lines = masked.lines
        raw.each_line.with_index(1) do |line, line_num|
          next unless line.match?(INLINE_MARKER)

          suppressed << line_num
          masked_line = masked_lines[line_num - 1] || ""
          suppressed << line_num + 1 if masked_line.strip.empty?
        end
        suppressed
      end

      def read(file)
        File.read(file, encoding: Encoding::UTF_8)
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def relative(path)
        path.relative_path_from(@root).to_s
      rescue ArgumentError
        path.to_s
      end

      def normalize_allow_files(list)
        Array(list).map(&:to_s).to_set
      end
    end
  end
end
