# frozen_string_literal: true

require "json"
require "pathname"
require_relative "../version"
require_relative "config"
require_relative "libraries"
require_relative "discovery"
require_relative "usages"
require_relative "design_tokens"
require_relative "components_markdown"
require_relative "root_element"

module Guardrails
  module FeedRamp
    # The app's component library and design tokens, for coding agents:
    # `<output_dir>/manifest.json` for tools, `<output_dir>/COMPONENTS.md`
    # to read. Built from the source alone (no app boot, network or
    # model call), sorted, and without a timestamp, so the same source
    # always gives byte-identical files that are worth committing.
    class Manifest
      SCHEMA_VERSION = 1
      FILENAME = Config::MANIFEST_FILENAME
      MARKDOWN_FILENAME = Config::MARKDOWN_FILENAME

      attr_reader :root, :config

      def initialize(root:, config: Config.load(root))
        @root = Pathname(root)
        @config = config
      end

      def path
        @config.manifest_path(@root)
      end

      def markdown_path
        @config.markdown_path(@root)
      end

      def to_h
        @to_h ||= {
          "schema_version" => SCHEMA_VERSION,
          "generator" => generator,
          "libraries" => Libraries.detect(@root),
          "components" => discovery.components.map { |component| component_entry(component) },
          "tokens" => design_tokens.to_a
        }
      end

      def to_json(*)
        "#{JSON.pretty_generate(to_h)}\n"
      end

      def markdown
        ComponentsMarkdown.new(to_h, manifest_path: path.relative_path_from(@root).to_s).render
      end

      # Writes both files. Returns { path => :created | :updated | :unchanged }.
      def write
        { path => write_file(path, to_json), markdown_path => write_file(markdown_path, markdown) }
      end

      # Whether the files on disk differ from what the source gives now:
      # missing, edited, or built from other source or by another gem
      # version. Compared by content, so an edit that changes nothing in
      # the manifest (most view edits) doesn't make it stale.
      def stale?
        stale_paths.any?
      end

      # The files that are missing or differ from what the source gives.
      def stale_paths
        { path => -> { to_json }, markdown_path => -> { markdown } }
          .reject { |file, content| file.file? && file.read == content.call }.keys
      end

      private

      def generator
        "ui_guardrails #{VERSION}"
      end

      def discovery
        @discovery ||= Discovery.new(root: @root, config: @config)
      end

      def usages
        @usages ||= Usages.new(root: @root, config: @config, discovery: discovery)
      end

      def design_tokens
        @design_tokens ||= DesignTokens.new(root: @root, config: @config)
      end

      def component_entry(component)
        doc = component.info.doc
        {
          "name" => component.name,
          "kind" => component.kind,
          "file" => component.file,
          "line" => component.info.line,
          "template" => component.template,
          "superclass" => discovery.index.superclass_of(component.info),
          "root_element" => RootElement.for(component, @root, index: discovery.index),
          "description" => doc.text.empty? ? nil : doc.text,
          "params" => discovery.params(component),
          "slots" => discovery.slots(component),
          "previews" => previews_for(component),
          "example" => usages.example_for(component)&.to_h
        }
      end

      # One entry per preview method: Lookbook's variants and states.
      def previews_for(component)
        discovery.previews.select { |preview| preview.component.equal?(component) }.flat_map do |preview|
          preview.methods.map do |method|
            doc = preview.info.source.doc(method.location.start_line)
            {
              "name" => method.name.to_s,
              "label" => doc.tag("label"),
              "description" => doc.text.empty? ? nil : doc.text,
              "hidden" => !doc.tag("hidden").nil?,
              "params" => RubySource.params(method.parameters),
              "file" => preview.info.file,
              "line" => method.location.start_line
            }
          end
        end
      end

      def write_file(target, content)
        return :unchanged if target.file? && target.read == content

        status = target.exist? ? :updated : :created
        target.dirname.mkpath
        target.write(content)
        status
      end
    end
  end
end
