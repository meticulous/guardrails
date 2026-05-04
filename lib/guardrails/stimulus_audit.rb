# frozen_string_literal: true

require "pathname"

module Guardrails
  class StimulusAudit
    Result = Struct.new(:orphaned, :dead, keyword_init: true) do
      def violations?
        !orphaned.empty? || !dead.empty?
      end
    end

    CONTROLLER_DIR = "app/javascript/controllers"
    CONTROLLER_GLOB = "**/*_controller.{js,ts}"

    VIEW_PATTERNS = [
      "app/views/**/*.html.erb",
      "app/components/**/*.html.erb"
    ].freeze

    DATA_CONTROLLER_PATTERN = /data-controller\s*=\s*["']([^"']+)["']/

    # Ruby helper syntax: `tag.div(data: { controller: "foo" })` or
    # `link_to "x", url, data: { controller: "foo bar" }`. Allow `=>` rocket
    # syntax too. Capture the string passed as the `controller:` value.
    RUBY_DATA_CONTROLLER_PATTERN =
      /data:?\s*(?:=>)?\s*\{[^}]*?controller:?\s*(?:=>)?\s*["']([^"']+)["']/m

    def initialize(root:, output: $stdout)
      @root = Pathname(root)
      @output = output
    end

    def run
      defined = collect_defined_controllers
      referenced = collect_referenced_controllers

      result = Result.new(
        orphaned: (referenced - defined).sort,
        dead: (defined - referenced).sort
      )

      print_report(result)
      result
    end

    private

    def collect_defined_controllers
      base = @root.join(CONTROLLER_DIR)
      return [] unless base.exist?

      Dir.glob(base.join(CONTROLLER_GLOB)).map do |path|
        controller_name_from(Pathname(path).relative_path_from(base))
      end.uniq
    end

    def collect_referenced_controllers
      VIEW_PATTERNS.flat_map { |pattern| Dir.glob(@root.join(pattern)) }
        .flat_map { |path| extract_referenced(Pathname(path)) }
        .uniq
    end

    def extract_referenced(file)
      content = File.read(file, encoding: Encoding::UTF_8)
      [DATA_CONTROLLER_PATTERN, RUBY_DATA_CONTROLLER_PATTERN].flat_map do |pattern|
        content.scan(pattern).flat_map { |captures| captures[0].strip.split(/\s+/) }
      end
    end

    def controller_name_from(relative_path)
      stripped = relative_path.to_s.sub(/_controller\.(js|ts)\z/, "")
      stripped.gsub("/", "--").tr("_", "-")
    end

    def print_report(result)
      return unless result.violations?

      @output.puts ""
      unless result.orphaned.empty?
        noun = result.orphaned.length == 1 ? "controller" : "controllers"
        @output.puts "Guardrails stimulus: #{result.orphaned.length} orphaned #{noun} (referenced in HTML, no JS file)"
        result.orphaned.each { |name| @output.puts "  - #{name}" }
      end
      unless result.dead.empty?
        noun = result.dead.length == 1 ? "controller" : "controllers"
        @output.puts "Guardrails stimulus: #{result.dead.length} dead #{noun} (JS file, never referenced)"
        result.dead.each { |name| @output.puts "  - #{name}" }
      end
    end
  end
end
