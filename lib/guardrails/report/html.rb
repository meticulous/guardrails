# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "pathname"
require_relative "finding"
require_relative "summary"
require_relative "../version"

module Guardrails
  module Report
    # The audit as one self-contained HTML file: no server, no asset
    # pipeline, no network. Everything (CSS, the small filter script)
    # is inline, so the file works opened from disk, attached to a PR,
    # or published as a CI artifact.
    #
    # Renders from Report::Category / Report::Finding, the same data
    # the TUI browses — the two are views of one audit run.
    class Html
      DEFAULT_PATH = "tmp/guardrails/audit.html"
      TEMPLATE = File.expand_path("html/template.html.erb", __dir__)

      # "Open in editor" link schemes, chosen client-side and kept in
      # localStorage — the report can't know which editor its reader
      # uses, and a CI artifact is read by more than one person.
      EDITOR_URLS = {
        "VS Code" => "vscode://file/{path}:{line}:{column}",
        "Cursor" => "cursor://file/{path}:{line}:{column}",
        "Zed" => "zed://file/{path}:{line}:{column}",
        "TextMate" => "txmt://open?url=file://{path}&line={line}&column={column}",
        "RubyMine" => "x-mine://open?file={path}&line={line}&column={column}"
      }.freeze

      SEVERITY_LABEL = { error: "Error", warning: "Warning", suggestion: "Suggestion" }.freeze

      # `muted` — severities the run was told not to check (SEVERITY=).
      # Stated on the page so a filtered report can't pass for a full one.
      def initialize(categories:, root:, generated_at: Time.now, muted: [])
        @muted = muted
        @categories = categories
        @root = Pathname(root).expand_path
        @generated_at = generated_at
      end

      def render
        ERB.new(File.read(TEMPLATE, encoding: Encoding::UTF_8), trim_mode: "-").result(binding)
      end

      # Writes the report and returns the absolute path written.
      def write(path = DEFAULT_PATH)
        target = Pathname(path)
        target = @root.join(target) unless target.absolute?
        FileUtils.mkdir_p(target.dirname)
        File.write(target, render)
        target
      end

      private

      def h(text)
        ERB::Util.html_escape(text.to_s)
      end

      def findings
        @categories.flat_map(&:findings)
      end

      def project_name
        @root.basename.to_s
      end

      def severity_groups
        Summary::SEVERITY_ORDER.filter_map do |severity|
          group = @categories.select { |c| c.severity == severity }
          [severity, group] unless group.empty?
        end
      end

      def muted_note
        return nil if @muted.empty?

        "#{@muted.map { |s| "#{SEVERITY_LABEL[s].downcase}s" }.join(' and ')} not checked"
      end

      def severity_count(severity)
        findings.count { |f| f.severity == severity }
      end

      def anchor(category)
        "cat-#{category.name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')}"
      end

      def absolute(location)
        @root.join(location.file).to_s
      end

      # Lowercased text the client-side filter matches against.
      def search_text(finding)
        [finding.category, finding.title, finding.suggestion, *finding.files].compact.join(" ").downcase
      end

      # JSON embedded in a <script> must not be able to close it.
      def editor_urls_json
        JSON.generate(EDITOR_URLS).gsub("</", '<\/')
      end

      def pluralize(count, singular, plural = "#{singular}s")
        "#{count} #{count == 1 ? singular : plural}"
      end
    end
  end
end
