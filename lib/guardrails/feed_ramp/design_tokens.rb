# frozen_string_literal: true

require "pathname"
require "stringio"
require_relative "../tokens"

module Guardrails
  module FeedRamp
    # The design tokens agents should reach for. Starts from what
    # `ui_guardrails:tokens` reads (the configured colour and type-scale
    # files, a Tailwind v3 config), then adds custom properties from
    # `feed_ramp.token_files` and from the `:root { }` and Tailwind v4
    # `@theme { }` blocks in the app's stylesheets, so spacing and radius
    # tokens are found too. The extra sources are Feed Ramp's own:
    # `ui_guardrails:tokens` and the audit read what they always did.
    class DesignTokens
      BLOCK_START = /(?:@theme\b[^{;]*|:root\b[^{,;]*)\{/

      CATEGORIES = [
        [/\A(?:colou?r|bg|background|border-colou?r|fill|stroke)\b|-colou?r\b/, "color"],
        [/\A(?:spacing|space|gap|inset|size|container)\b/, "spacing"],
        [/\A(?:text|font|leading|tracking|line-height|letter-spacing|type)\b/, "typography"],
        [/\A(?:radius|rounded|border-radius)\b/, "radius"],
        [/\A(?:shadow|drop-shadow|elevation)\b/, "shadow"],
        [/\A(?:breakpoint|screen)\b/, "breakpoint"],
        [/\A(?:ease|animate|duration|transition)\b/, "motion"]
      ].freeze

      COLOR_VALUE = /\A(?:#\h{3,8}\b|(?:rgb|hsl|oklch|oklab|lab|lch|color)a?\()/i

      def initialize(root:, config:)
        @root = Pathname(root)
        @config = config
        @tokens = Tokens.new(root: @root, output: StringIO.new)
      end

      # One entry per token name, the first definition found winning (a
      # dark-mode `:root` override doesn't replace the default value).
      def to_a
        found = @tokens.parse_tokens.map { |t| entry(t.name, t.value, t.syntax, t.file.to_s, t.line) }
        found += token_files.flat_map { |file| custom_properties(file, whole_file: true) }
        found += stylesheets.flat_map { |file| custom_properties(file, whole_file: false) }
        found.uniq { |t| t["name"] }.sort_by { |t| t["name"] }
      end

      private

      def token_files
        @config.token_files.select { |file| @root.join(file).file? }
      end

      def stylesheets
        Tokens::STYLESHEET_PATTERNS.flat_map { |pattern| Dir.glob(@root.join(pattern)) }.uniq.sort
                                   .map { |path| relative(Pathname(path)) }
                                   .reject { |file| (Tokens::IMPLICIT_IGNORE_SEGMENTS & file.split("/")).any? }
      end

      def custom_properties(file, whole_file:)
        text = @tokens.strip_comments(File.read(@root.join(file), encoding: Encoding::UTF_8))
        ranges = whole_file ? [0...text.length] : blocks(text)
        ranges.flat_map do |range|
          found = []
          text[range].to_enum(:scan, Tokens::CSS_VAR_PATTERN).each do
            match = Regexp.last_match
            line = text[0, range.begin + match.begin(0)].count("\n") + 1
            found << entry(match[1], match[2].strip, :css_var, file, line)
          end
          found
        end
      end

      # Character ranges of each `:root { }` / `@theme { }` body.
      def blocks(text)
        ranges = []
        offset = 0
        while (match = BLOCK_START.match(text, offset))
          depth = 1
          i = match.end(0)
          while i < text.length && depth.positive?
            depth += 1 if text[i] == "{"
            depth -= 1 if text[i] == "}"
            i += 1
          end
          ranges << (match.end(0)...(i - 1))
          offset = i
        end
        ranges
      end

      def entry(name, value, syntax, file, line)
        written = case syntax.to_sym
                  when :css_var then "--#{name}"
                  when :scss_var then "$#{name}"
                  else name
                  end
        { "name" => written, "value" => value, "syntax" => syntax.to_s, "category" => category(name, value, syntax),
          "file" => file, "line" => line.zero? ? nil : line }
      end

      def category(name, value, syntax)
        return "color" if syntax.to_sym == :tailwind # v3 configs are parsed for colours only

        CATEGORIES.each { |pattern, category| return category if name.match?(pattern) }
        value.match?(COLOR_VALUE) ? "color" : "other"
      end

      def relative(path)
        path.relative_path_from(@root).to_s
      end
    end
  end
end
