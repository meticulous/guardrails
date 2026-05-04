# frozen_string_literal: true

require "pathname"
require "yaml"
require_relative "hex_normalizer"

module Guardrails
  class Tokens
    Token = Struct.new(:name, :value, :syntax, :file, :line, keyword_init: true)
    Drift = Struct.new(:file, :line, :column, :value, :matched_token, keyword_init: true)

    CSS_VAR_PATTERN = /--([a-z][\w-]*):\s*([^;]+);/i
    SCSS_VAR_PATTERN = /\$([a-z][\w-]*):\s*([^;]+);/i
    HEX_LITERAL_PATTERN = /#[0-9a-fA-F]{3,8}\b/
    STYLESHEET_PATTERNS = [
      "app/assets/stylesheets/**/*.{css,scss}",
      "app/assets/tailwind/**/*.css"
    ].freeze

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
      file = colors_file
      return [] unless file && file.exist?

      content = File.read(file, encoding: Encoding::UTF_8)
      tokens = []
      tokens.concat(scan(content, file, CSS_VAR_PATTERN, :css_var))
      tokens.concat(scan(content, file, SCSS_VAR_PATTERN, :scss_var))
      tokens
    end

    def detect_drift(tokens)
      lookup = tokens.to_h { |t| [HexNormalizer.normalize(t.value), t] }
      drift = []

      stylesheets.each do |file|
        next if file == colors_file

        content = File.read(file, encoding: Encoding::UTF_8)
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
      relative = @config.dig("guardrails", "tokens", "colors_file")
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
    end

    def variable_definition_line?(line)
      line.match?(SCSS_VAR_PATTERN) || line.match?(CSS_VAR_PATTERN)
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
      prefix = token.syntax == :css_var ? "var(--" : "$"
      suffix = token.syntax == :css_var ? ")" : ""
      "#{prefix}#{token.name}#{suffix}"
    end

    def print_summary(tokens)
      file = colors_file
      if file.nil?
        @output.puts "Guardrails tokens: no colors_file configured in guardrails.yml"
        return
      end
      unless file.exist?
        @output.puts "Guardrails tokens: configured colors_file does not exist (#{file.relative_path_from(@root)})"
        return
      end
      if tokens.empty?
        @output.puts "Guardrails tokens: 0 tokens found in #{file.relative_path_from(@root)}"
        return
      end
      @output.puts "Guardrails tokens: #{tokens.length} token#{'s' if tokens.length != 1} found in #{file.relative_path_from(@root)}"
      tokens.each { |t| @output.puts "  #{t.syntax == :css_var ? '--' : '$'}#{t.name} = #{t.value}" }
    end
  end
end
