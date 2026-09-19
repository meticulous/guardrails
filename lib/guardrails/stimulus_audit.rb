# frozen_string_literal: true

require "pathname"
require_relative "report/style"
require_relative "report/finding"

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

    # Detector-agnostic view of `result` (see Report::Finding). Unlike
    # the text report, findings carry locations: every view line that
    # references an orphaned controller, and the JS file behind a dead
    # one — the names alone don't tell you where to go.
    def categories(result)
      [
        Report::Category.new(
          name: "stimulus orphaned", severity: :warning, framing: ORPHANED_FRAMING.join(" "),
          findings: result.orphaned.map { |name|
            Report::Finding.new(
              category: "stimulus orphaned", severity: :warning,
              title: "stimulus orphaned: #{name}", suggestion: orphaned_suggestion(name),
              locations: reference_locations(name)
            )
          }
        ),
        Report::Category.new(
          name: "stimulus dead", severity: :warning, framing: DEAD_FRAMING.join(" "),
          findings: result.dead.map { |name|
            Report::Finding.new(
              category: "stimulus dead", severity: :warning,
              title: "stimulus dead: #{name}", suggestion: dead_suggestion(name),
              locations: controller_locations(name)
            )
          }
        )
      ].reject { |c| c.findings.empty? }
    end

    private

    ORPHANED_FRAMING = [
      "data-controller=\"…\" references a Stimulus controller, but no matching",
      "*_controller.{js,ts} file exists. Either create the controller or",
      "remove the reference."
    ].freeze

    DEAD_FRAMING = [
      "*_controller.{js,ts} file exists, but no view references it via",
      "data-controller=\"…\". Either wire the controller into a template",
      "or delete the file."
    ].freeze

    def orphaned_suggestion(name)
      "create app/javascript/controllers/#{name}_controller.js or remove the data-controller=\"#{name}\" reference"
    end

    def dead_suggestion(name)
      "reference it via data-controller=\"#{name}\" in a view, or delete the JS file"
    end

    def controller_paths
      CONTROLLER_BASES.flat_map do |base|
        absolute = @root.join(base)
        next [] unless absolute.exist?

        Dir.glob(absolute.join(CONTROLLER_GLOB))
      end
    end

    def controller_locations(name)
      controller_paths.select { |path| controller_name_from_path(path) == name }.sort.map do |path|
        Report::Location.new(file: Pathname(path).relative_path_from(@root).to_s)
      end
    end

    # Line-level lookup, only run for the (usually few) orphaned names
    # — the main pass reads whole files and keeps names only. A
    # reference the patterns only match across lines (a multi-line
    # `data: { controller: ... }` hash) falls back to a file-level
    # location rather than dropping out.
    def reference_locations(name)
      VIEW_PATTERNS.flat_map { |pattern| Dir.glob(@root.join(pattern)) }.sort.flat_map do |path|
        content = File.read(path, encoding: Encoding::UTF_8)
        next [] unless extract_names(content).include?(name)

        relative = Pathname(path).relative_path_from(@root).to_s
        lines = content.each_line.with_index(1).filter_map do |line, number|
          Report::Location.new(file: relative, line: number) if extract_names(line).include?(name)
        end
        lines.empty? ? [Report::Location.new(file: relative)] : lines
      end
    end

    def collect_defined_controllers
      controller_paths.map { |path| controller_name_from_path(path) }.compact.uniq
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
      extract_names(File.read(file, encoding: Encoding::UTF_8))
    end

    def extract_names(content)
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
        ORPHANED_FRAMING.each { |line| @output.puts "  #{line}" }
        result.orphaned.each do |name|
          @output.puts ""
          @output.puts "  #{@style.severity(:warning, "stimulus orphaned: #{name}")}"
          @output.puts "    #{@style.suggestion(orphaned_suggestion(name))}"
        end
      end

      unless result.dead.empty?
        noun = result.dead.length == 1 ? "controller" : "controllers"
        @output.puts ""
        @output.puts @style.section_heading(
          :warning,
          "stimulus dead (#{result.dead.length} #{noun})"
        )
        DEAD_FRAMING.each { |line| @output.puts "  #{line}" }
        result.dead.each do |name|
          @output.puts ""
          @output.puts "  #{@style.severity(:warning, "stimulus dead: #{name}")}"
          @output.puts "    #{@style.suggestion(dead_suggestion(name))}"
        end
      end
    end
  end
end
