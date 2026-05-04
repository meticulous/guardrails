# frozen_string_literal: true

require "pathname"
require "yaml"

module Guardrails
  class Tokens
    Token = Struct.new(:name, :value, :syntax, :file, :line, keyword_init: true)

    CSS_VAR_PATTERN = /--([a-z][\w-]*):\s*([^;]+);/i
    SCSS_VAR_PATTERN = /\$([a-z][\w-]*):\s*([^;]+);/i

    def initialize(root:, output: $stdout)
      @root = Pathname(root)
      @output = output
      @config = load_config
    end

    def run
      tokens = parse_tokens
      print_summary(tokens)
      tokens
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
