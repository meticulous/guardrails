# frozen_string_literal: true

require "pathname"

module Guardrails
  class Tokens
    # Best-effort regex/character-walk parser for Tailwind v3 config files.
    # Extracts color entries from `theme.colors` and `theme.extend.colors`
    # blocks. Handles flat scalars and one level of nested scales (per
    # Tailwind convention: `gray: { 50: "#f9fafb" }` flattens to
    # `gray-50`).
    #
    # Known limitations (out of scope for V0):
    # - Function-valued entries (`primary: defineColor("blue")`)
    # - Spread operators (`...palette`)
    # - require()/import() of external palettes
    # - Computed keys
    # - TypeScript configs with type annotations on values
    #
    # For any of these the entry is silently skipped; the user is
    # encouraged to migrate to Tailwind v4 `@theme` (CSS-first) which
    # parses cleanly through the existing CSS custom property path.
    class TailwindConfigParser
      Entry = Struct.new(:name, :value, keyword_init: true)

      COLORS_BLOCK_HEADER = /\bcolors\s*:\s*\{/

      def self.parse(content)
        new(content).parse
      end

      def initialize(content)
        @content = content
      end

      def parse
        entries = []
        scan_colors_blocks do |body|
          entries.concat(extract_entries(body))
        end
        entries
      end

      private

      def scan_colors_blocks
        pos = 0
        while (m = @content.match(COLORS_BLOCK_HEADER, pos))
          brace_idx = m.end(0) - 1
          body = balanced_extract(@content, brace_idx)
          break unless body

          yield body
          pos = brace_idx + body.length + 2
        end
      end

      def balanced_extract(text, start_idx)
        return nil unless text[start_idx] == "{"

        depth = 0
        i = start_idx
        while i < text.length
          case text[i]
          when "{" then depth += 1
          when "}" then depth -= 1
          end
          return text[(start_idx + 1)...i] if depth.zero?

          i += 1
        end
        nil
      end

      def extract_entries(body)
        entries = []
        i = 0
        while i < body.length
          i = skip_separators(body, i)
          break if i >= body.length

          key, advance = parse_key(body, i)
          unless key
            # Unparseable token at this position (e.g. `...spread` or a
            # syntax we don't support). Skip to the next comma and keep going
            # rather than abandoning subsequent entries.
            i = body.index(/,/, i) || body.length
            i += 1 if i < body.length
            next
          end

          i = skip_to_value(body, i + advance)
          break if i >= body.length

          if body[i] == "{"
            nested = balanced_extract(body, i)
            break unless nested

            extract_entries(nested).each do |child|
              entries << Entry.new(name: "#{key}-#{child.name}", value: child.value)
            end
            i += nested.length + 2
          elsif (quote = body[i]) =~ /["']/
            end_idx = body.index(quote, i + 1)
            break unless end_idx

            entries << Entry.new(name: key, value: body[(i + 1)...end_idx])
            i = end_idx + 1
          else
            i = body.index(/,/, i) || body.length
          end
        end
        entries
      end

      def skip_separators(body, i)
        i += 1 while i < body.length && body[i] =~ /[\s,]/
        i
      end

      def skip_to_value(body, i)
        i += 1 while i < body.length && body[i] =~ /[\s:]/
        i
      end

      def parse_key(body, start)
        if body[start] =~ /["']/
          quote = body[start]
          end_idx = body.index(quote, start + 1)
          return [nil, 0] unless end_idx

          [body[(start + 1)...end_idx], end_idx - start + 1]
        else
          m = body[start..].match(/\A([a-zA-Z_0-9][\w-]*)/)
          return [nil, 0] unless m

          [m[1], m[1].length]
        end
      end
    end
  end
end
