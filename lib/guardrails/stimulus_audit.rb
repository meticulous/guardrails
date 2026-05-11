# frozen_string_literal: true

require "pathname"
require_relative "report/style"

module Guardrails
  class StimulusAudit
    Result = Struct.new(:orphaned, :dead, keyword_init: true) do
      def violations?
        !orphaned.empty? || !dead.empty?
      end
    end

    # Stimulus controller files can live under different layouts depending
    # on bundler / app structure:
    #
    #   app/javascript/controllers/*_controller.{js,ts}        (importmap default)
    #   app/javascript/js/controllers/*_controller.{js,ts}     (Avo)
    #   app/javascript/packs/controllers/*_controller.{js,ts}  (older Webpacker)
    #   app/frontend/controllers/*_controller.{js,ts}          (Vite Rails)
    #
    # Glob from each accepted base; controller-name derivation hinges on
    # the deepest `controllers/` segment in the path.
    CONTROLLER_BASES = %w[app/javascript app/frontend].freeze
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

    def initialize(root:, output: $stdout, style: nil)
      @root = Pathname(root)
      @output = output
      @style = style || Report::Style.new(io: output)
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
      paths = CONTROLLER_BASES.flat_map do |base|
        absolute = @root.join(base)
        next [] unless absolute.exist?

        Dir.glob(absolute.join(CONTROLLER_GLOB))
      end
      paths.map { |path| controller_name_from_path(path) }.compact.uniq
    end

    # Derive a Stimulus controller identifier from a file path. We anchor
    # on the deepest `controllers/` directory in the path, so:
    #
    #   app/javascript/controllers/users/profile_controller.js → "users--profile"
    #   app/javascript/js/controllers/foo_controller.js        → "foo"
    #   app/frontend/controllers/admin/users_controller.ts     → "admin--users"
    #
    # Falls back to the basename when no `controllers/` segment exists.
    def controller_name_from_path(path)
      str = path.to_s
      marker = "/controllers/"
      idx = str.rindex(marker)
      relative = idx ? str[(idx + marker.length)..] : File.basename(str)

      stripped = relative.sub(/_controller\.(js|ts)\z/, "")
      return nil if stripped.empty?

      stripped.gsub("/", "--").tr("_", "-")
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

    def print_report(result)
      return unless result.violations?

      unless result.orphaned.empty?
        noun = result.orphaned.length == 1 ? "controller" : "controllers"
        @output.puts ""
        @output.puts @style.section_heading(
          :warning,
          "stimulus orphaned (#{result.orphaned.length} #{noun})"
        )
        @output.puts "  data-controller=\"…\" references a Stimulus controller, but no matching"
        @output.puts "  *_controller.{js,ts} file exists. Either create the controller or"
        @output.puts "  remove the reference."
        result.orphaned.each do |name|
          @output.puts ""
          @output.puts "  #{@style.severity(:warning, "stimulus orphaned: #{name}")}"
          @output.puts "    #{@style.suggestion("create app/javascript/controllers/#{name}_controller.js or remove the data-controller=\"#{name}\" reference")}"
        end
      end

      unless result.dead.empty?
        noun = result.dead.length == 1 ? "controller" : "controllers"
        @output.puts ""
        @output.puts @style.section_heading(
          :warning,
          "stimulus dead (#{result.dead.length} #{noun})"
        )
        @output.puts "  *_controller.{js,ts} file exists, but no view references it via"
        @output.puts "  data-controller=\"…\". Either wire the controller into a template"
        @output.puts "  or delete the file."
        result.dead.each do |name|
          @output.puts ""
          @output.puts "  #{@style.severity(:warning, "stimulus dead: #{name}")}"
          @output.puts "    #{@style.suggestion("reference it via data-controller=\"#{name}\" in a view, or delete the JS file")}"
        end
      end
    end
  end
end
