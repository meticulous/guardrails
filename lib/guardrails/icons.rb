# frozen_string_literal: true

require "pathname"
require "yaml"

module Guardrails
  class Icons
    Violation = Struct.new(:type, :file, :line, :column, :snippet, keyword_init: true)

    DEFAULT_SOURCE = "app/assets/images/icons"
    DEFAULT_SPRITE_OUTPUT = "app/assets/images/icons/sprite.svg"
    DEFAULT_VIEWBOX = "0 0 24 24"

    VIEW_PATTERNS = [
      "app/views/**/*.html.erb",
      "app/components/**/*.html.erb"
    ].freeze

    SVG_OPEN_TAG = /<svg\b([^>]*)>/m
    SVG_INNER = /<svg\b[^>]*>([\s\S]*?)<\/svg>/m
    SVG_BLOCK_PATTERN = /<svg\b[^>]*>[\s\S]*?<\/svg>/m
    VIEWBOX_ATTR = /\bviewBox\s*=\s*["']([^"']+)["']/i
    ERB_BLOCK_PATTERN = /<%[\s\S]*?%>/

    def initialize(root:, output: $stdout, source: nil, sprite_output: nil)
      @root = Pathname(root)
      @output = output
      config = load_config

      @source = resolve_path(source || config.dig("guardrails", "icons", "source") || DEFAULT_SOURCE)
      @sprite_output = resolve_path(sprite_output || config.dig("guardrails", "icons", "sprite_output") || DEFAULT_SPRITE_OUTPUT)
    end

    def run
      generate_sprite
      violations = audit_inline_svgs
      report_inline_svgs(violations)
      violations
    end

    def audit_inline_svgs
      view_files.flat_map { |file| scan_view_for_inline_svgs(file) }
    end

    def generate_sprite
      svgs = collect_svgs
      if svgs.empty?
        @output.puts "No SVGs found in #{relative(@source)}"
        return nil
      end

      symbols = svgs.filter_map { |file| build_symbol(file) }
      sprite = wrap_sprite(symbols)

      @sprite_output.dirname.mkpath
      File.write(@sprite_output, sprite, encoding: Encoding::UTF_8)
      @output.puts "Wrote sprite with #{symbols.length} icons to #{relative(@sprite_output)}"
      @sprite_output
    end

    private

    def load_config
      path = @root.join("guardrails.yml")
      return {} unless path.exist?

      YAML.safe_load_file(path) || {}
    end

    def resolve_path(path)
      pathname = Pathname(path)
      pathname.absolute? ? pathname : @root.join(pathname)
    end

    def collect_svgs
      return [] unless @source.exist?

      Dir.glob(@source.join("*.svg"))
        .map { |path| Pathname(path) }
        .reject { |path| path == @sprite_output }
        .sort_by { |path| path.basename.to_s }
    end

    def build_symbol(file)
      content = File.read(file, encoding: Encoding::UTF_8)
      open_tag = content.match(SVG_OPEN_TAG)
      inner_match = content.match(SVG_INNER)
      return nil unless open_tag && inner_match

      viewbox = open_tag[1].match(VIEWBOX_ATTR)&.[](1) || DEFAULT_VIEWBOX
      inner = inner_match[1].strip
      return nil if inner.empty?

      name = file.basename(".svg").to_s
      %(  <symbol id="icon-#{name}" viewBox="#{viewbox}">#{inner}</symbol>)
    end

    def wrap_sprite(symbols)
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" style="display: none">
        #{symbols.join("\n")}
        </svg>
      SVG
    end

    def relative(path)
      path.relative_path_from(@root).to_s
    rescue ArgumentError
      path.to_s
    end

    def view_files
      VIEW_PATTERNS
        .flat_map { |pattern| Dir.glob(@root.join(pattern)) }
        .map { |path| Pathname(path) }
        .uniq
    end

    def scan_view_for_inline_svgs(file)
      content = File.read(file, encoding: Encoding::UTF_8)
      masked = mask_erb(content)

      violations = []
      masked.scan(SVG_BLOCK_PATTERN) do
        match = Regexp.last_match
        block = match[0]
        next if block.include?("<use")

        offset = match.begin(0)
        line_num = masked[0...offset].count("\n") + 1

        violations << Violation.new(
          type: :inline_svg,
          file: file.relative_path_from(@root).to_s,
          line: line_num,
          column: 1,
          snippet: block.lines.first&.chomp&.strip
        )
      end
      violations
    end

    def mask_erb(content)
      content.gsub(ERB_BLOCK_PATTERN) do |match|
        newline_count = match.count("\n")
        "\n" * newline_count + " " * (match.length - newline_count)
      end
    end

    def report_inline_svgs(violations)
      return if violations.empty?

      noun = violations.length == 1 ? "inline SVG" : "inline SVGs"
      @output.puts ""
      @output.puts "Guardrails icons: #{violations.length} #{noun} found in views (should reference the sprite via <use>)"
      violations.each do |v|
        @output.puts "  [#{v.type}] #{v.file}:#{v.line}"
        @output.puts "    #{v.snippet}"
      end
    end
  end
end
