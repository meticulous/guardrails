# frozen_string_literal: true

require "pathname"
require "yaml"
require_relative "hex_normalizer"
require_relative "tokens/tailwind_config_parser"

module Guardrails
  class Tokens
    Token = Struct.new(:name, :value, :syntax, :file, :line, keyword_init: true)
    Drift = Struct.new(:file, :line, :column, :value, :matched_token, keyword_init: true)

    CSS_VAR_PATTERN = /--([a-z][\w-]*):\s*([^;]+);/i
    SCSS_VAR_PATTERN = /\$([a-z][\w-]*):\s*([^;]+);/i
    HEX_LITERAL_PATTERN = /#[0-9a-fA-F]{3,8}\b/
    BLOCK_COMMENT_PATTERN = /\/\*[\s\S]*?\*\//
    LINE_COMMENT_PATTERN = /\/\/[^\n]*/
    STYLESHEET_PATTERNS = [
      "app/assets/stylesheets/**/*.{css,scss}",
      "app/assets/tailwind/**/*.css"
    ].freeze

    # Same path-component skip-list as Audit / StackDetector — vendor
    # stylesheets nested under app/assets/stylesheets/ shouldn't surface
    # as drift since they're typically third-party.
    IMPLICIT_IGNORE_SEGMENTS = %w[vendor node_modules tmp public log].freeze

    def initialize(root:, output: $stdout)
      @root = Pathname(root)
      @output = output
      @config = load_config
    end

    def run
      tokens = parse_tokens
      drift = detect_drift(tokens)
      print_summary(tokens)
      print_drift(drift)
      { tokens: tokens, drift: drift }
    end

    def parse_tokens
      tokens = []
      [colors_file, type_scale_file].compact.each do |file|
        next unless file.exist?

        content = File.read(file, encoding: Encoding::UTF_8)
        tokens.concat(scan(content, file, CSS_VAR_PATTERN, :css_var))
        tokens.concat(scan(content, file, SCSS_VAR_PATTERN, :scss_var))
      end
      tokens.concat(parse_tailwind_config)
      tokens
    end

    def parse_tailwind_config
      file = @root.join("tailwind.config.js")
      return [] unless file.exist?

      content = File.read(file, encoding: Encoding::UTF_8)
      TailwindConfigParser.parse(content).map do |entry|
        Token.new(
          name: entry.name,
          value: entry.value,
          syntax: :tailwind,
          file: file.relative_path_from(@root).to_s,
          line: 0
        )
      end
    end

    def detect_drift(tokens)
      lookup = tokens.to_h { |t| [HexNormalizer.normalize(t.value), t] }
      drift = []
      definition_files = [colors_file, type_scale_file].compact

      stylesheets.each do |file|
        next if definition_files.include?(file)
        next if file == @root.join("tailwind.config.js")

        raw_content = File.read(file, encoding: Encoding::UTF_8)
        content = strip_comments(raw_content)
        content.each_line.with_index do |line, idx|
          next if variable_definition_line?(line)

          line.scan(HEX_LITERAL_PATTERN) do
            value = Regexp.last_match[0]
            column = Regexp.last_match.begin(0) + 1
            drift << Drift.new(
              file: file.relative_path_from(@root).to_s,
              line: idx + 1,
              column: column,
              value: value,
              matched_token: lookup[HexNormalizer.normalize(value)]
            )
          end
        end
      end
      drift
    end

    private

    def load_config
      path = @root.join("guardrails.yml")
      return {} unless path.exist?

      YAML.safe_load_file(path) || {}
    end

    def colors_file
      configured_token_file("colors_file")
    end

    def type_scale_file
      configured_token_file("type_scale_file")
    end

    def configured_token_file(key)
      relative = @config.dig("guardrails", "tokens", key)
      return nil unless relative

      @root.join(relative)
    end

    def scan(content, file, pattern, syntax)
      tokens = []
      content.each_line.with_index do |line, idx|
        line.scan(pattern) do
          match = Regexp.last_match
          tokens << Token.new(
            name: match[1],
            value: match[2].strip,
            syntax: syntax,
            file: file.relative_path_from(@root).to_s,
            line: idx + 1
          )
        end
      end
      tokens
    end

    def stylesheets
      STYLESHEET_PATTERNS
        .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
        .map { |path| Pathname(path) }
        .uniq
        .reject { |path| ignored_segment?(path) }
    end

    def ignored_segment?(path)
      segments = path.relative_path_from(@root).to_s.split("/")
      (IMPLICIT_IGNORE_SEGMENTS & segments).any?
    end

    def variable_definition_line?(line)
      line.match?(SCSS_VAR_PATTERN) || line.match?(CSS_VAR_PATTERN)
    end

    # Replace CSS/SCSS comments with whitespace, preserving line/column
    # positions so reported drift coordinates remain accurate.
    def strip_comments(content)
      content
        .gsub(BLOCK_COMMENT_PATTERN) { |m| mask_chars(m) }
        .gsub(LINE_COMMENT_PATTERN) { |m| " " * m.length }
    end

    def mask_chars(string)
      string.gsub(/[^\n]/, " ")
    end

    def print_drift(drift)
      return if drift.empty?

      @output.puts ""
      @output.puts "Guardrails tokens: #{drift.length} color literal#{'s' if drift.length != 1} found in stylesheets outside the token file"
      drift.each do |d|
        suffix = d.matched_token ? " — matches #{format_token_name(d.matched_token)}" : " — no matching token"
        @output.puts "  #{d.file}:#{d.line}:#{d.column}  #{d.value}#{suffix}"
      end
    end

    def format_token_name(token)
      case token.syntax
      when :css_var then "var(--#{token.name})"
      when :scss_var then "$#{token.name}"
      when :tailwind then "Tailwind theme color `#{token.name}`"
      else token.name.to_s
      end
    end

    def print_summary(tokens)
      configured_sources = [colors_file, type_scale_file].compact
      tailwind_path = @root.join("tailwind.config.js")
      tailwind_source = tailwind_path.exist? ? tailwind_path : nil
      all_sources = configured_sources + [tailwind_source].compact

      if all_sources.empty?
        @output.puts "Guardrails tokens: no colors_file, type_scale_file, or tailwind.config.js found"
        return
      end

      missing = configured_sources.reject(&:exist?)
      if missing.any?
        missing.each do |f|
          relative = f.relative_path_from(@root)
          key = (f == colors_file) ? "tokens.colors_file" : "tokens.type_scale_file"
          @output.puts "Guardrails tokens: configured #{key} does not exist (#{relative})"
        end
        @output.puts "  → Edit guardrails.yml to point at your real token file, or set FORCE=1 and re-run guardrails:init to regenerate config."
      end

      existing_sources = all_sources.select(&:exist?)
      return if existing_sources.empty?

      labels = existing_sources.map { |f| f.relative_path_from(@root).to_s }.join(", ")
      if tokens.empty?
        @output.puts "Guardrails tokens: 0 tokens found in #{labels}"
        return
      end
      @output.puts "Guardrails tokens: #{tokens.length} token#{'s' if tokens.length != 1} found in #{labels}"
      tokens.each { |t| @output.puts "  #{format_token_name(t)} = #{t.value}" }
    end
  end
end
