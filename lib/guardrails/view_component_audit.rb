# frozen_string_literal: true

require "pathname"
require_relative "report/style"

module Guardrails
  class ViewComponentAudit
    Result = Struct.new(:missing_previews, :orphan_slots, keyword_init: true) do
      def violations?
        !missing_previews.empty? || !orphan_slots.empty?
      end
    end

    OrphanSlot = Struct.new(:component, :slot, :slot_kind, :file, :line, keyword_init: true)

    COMPONENT_DIR = "app/components"
    COMPONENT_GLOB = "**/*_component.rb"
    PREVIEW_DIRS = [
      "test/components/previews",
      "spec/components/previews"
    ].freeze
    PREVIEW_GLOB = "**/*_component_preview.rb"

    SLOT_PATTERN = /^\s*(renders_one|renders_many)\s+:([a-z_][\w]*)/

    def initialize(root:, output: $stdout, style: nil)
      @root = Pathname(root)
      @output = output
      @style = style || Report::Style.new(io: output)
    end

    def run
      result = Result.new(
        missing_previews: find_missing_previews,
        orphan_slots: find_orphan_slots
      )
      print_report(result)
      result
    end

    def find_missing_previews
      defined = collect_components
      previewed = collect_previews
      (defined - previewed).sort
    end

    def find_orphan_slots
      orphans = []
      component_files.each do |path|
        slots = parse_slot_declarations(path)
        next if slots.empty?

        template_path = template_for(path)
        template_content = template_path.exist? ? File.read(template_path, encoding: Encoding::UTF_8) : ""

        slots.each do |slot|
          next if rendered_in_template?(template_content, slot[:name])

          orphans << OrphanSlot.new(
            component: relative_component_name(path),
            slot: slot[:name],
            slot_kind: slot[:kind],
            file: path.relative_path_from(@root).to_s,
            line: slot[:line]
          )
        end
      end
      orphans
    end

    private

    def component_files
      base = @root.join(COMPONENT_DIR)
      return [] unless base.exist?

      Dir.glob(base.join(COMPONENT_GLOB)).map { |p| Pathname(p) }.sort
    end

    def collect_components
      base = @root.join(COMPONENT_DIR)
      return [] unless base.exist?

      Dir.glob(base.join(COMPONENT_GLOB)).map do |p|
        component_name(Pathname(p).relative_path_from(base))
      end
    end

    def collect_previews
      PREVIEW_DIRS.flat_map do |dir|
        base = @root.join(dir)
        next [] unless base.exist?

        Dir.glob(base.join(PREVIEW_GLOB)).map do |p|
          preview_name(Pathname(p).relative_path_from(base))
        end
      end.uniq
    end

    def component_name(relative_path)
      relative_path.to_s.sub(/_component\.rb\z/, "")
    end

    def preview_name(relative_path)
      relative_path.to_s.sub(/_component_preview\.rb\z/, "")
    end

    def relative_component_name(path)
      base = @root.join(COMPONENT_DIR)
      component_name(path.relative_path_from(base))
    end

    def template_for(component_path)
      component_path.sub_ext(".html.erb")
    end

    def parse_slot_declarations(path)
      slots = []
      File.read(path, encoding: Encoding::UTF_8).each_line.with_index do |line, idx|
        m = line.match(SLOT_PATTERN)
        next unless m

        slots << { kind: m[1].to_sym, name: m[2], line: idx + 1 }
      end
      slots
    end

    def rendered_in_template?(content, slot_name)
      # Look for any reference to the slot — `<%= slot_name %>`, `slot_name?`,
      # or `slot_name.each` / `slot_name.map` for renders_many.
      content.match?(/\b#{Regexp.escape(slot_name)}\b/)
    end

    def print_report(result)
      return unless result.violations?

      unless result.missing_previews.empty?
        noun = result.missing_previews.length == 1 ? "component" : "components"
        @output.puts ""
        @output.puts @style.section_heading(
          :warning,
          "view_components missing previews (#{result.missing_previews.length} #{noun})"
        )
        @output.puts "  Component classes without a corresponding Lookbook preview file."
        @output.puts "  Add #{noun} previews so the component is discoverable + visually testable."
        result.missing_previews.each do |name|
          @output.puts ""
          @output.puts "  #{@style.severity(:warning, "missing preview: #{name}_component")}"
          @output.puts "    #{@style.suggestion("create test/components/previews/#{name}_component_preview.rb (or lookbook/previews/...)")}"
        end
      end

      unless result.orphan_slots.empty?
        noun = result.orphan_slots.length == 1 ? "slot" : "slots"
        @output.puts ""
        @output.puts @style.section_heading(
          :warning,
          "view_components orphan slots (#{result.orphan_slots.length} #{noun})"
        )
        @output.puts "  renders_one / renders_many declared in the component class but never"
        @output.puts "  referenced in the template. Either reference the slot or remove the"
        @output.puts "  declaration."
        result.orphan_slots.each do |o|
          @output.puts ""
          header = "orphan slot: #{o.component}_component##{o.slot} (#{o.slot_kind})"
          @output.puts "  #{@style.severity(:warning, header)}"
          @output.puts "    #{@style.suggestion("reference :#{o.slot} in the template, or remove the #{o.slot_kind} declaration")}"
          @output.puts "    #{@style.location("#{o.file}:#{o.line}")}"
        end
      end
    end
  end
end
