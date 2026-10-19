# frozen_string_literal: true

require "pathname"
require "prism"
require "stringio"
require_relative "../audit"
require_relative "../a11y_audit"
require_relative "../erb_parser"
require_relative "ruby_source"

module Guardrails
  module FeedRamp
    # Checks a snippet an agent is about to write, before it's in a file:
    # the audit's and static a11y's findings for ERB, and for ERB and Ruby
    # alike, each `SomeComponent.new(...)` against the manifest (a
    # component that doesn't exist, a keyword it doesn't take, a required
    # one left out, too many or too few positional arguments).
    class SnippetCheck
      DEFAULT_PATH = "app/views/_snippet.html.erb"

      def initialize(root:, manifest:)
        @root = Pathname(root)
        @components = manifest.fetch("components", [])
      end

      # `language` is "erb" or "ruby"; guessed from the source when nil.
      # `path` is where the snippet will live, which decides what the
      # audit checks (a component's own template isn't matched against
      # itself).
      def call(source, language: nil, path: nil)
        language = (language || guess_language(source)).to_s.downcase
        raise ArgumentError, "language must be erb or ruby, not #{language.inspect}" unless %w[erb ruby].include?(language)

        path = (path.nil? || path.to_s.strip.empty? ? DEFAULT_PATH : path.to_s).delete_prefix("./")
        findings = language == "erb" ? erb_findings(source, path) : ruby_findings(source)
        { "language" => language, "path" => path, "ok" => findings.none? { |f| %w[error warning].include?(f["severity"]) },
          "findings" => findings.sort_by { |f| [f["line"].to_i, f["rule"]] } }
      end

      private

      def guess_language(source)
        source.match?(/<%|\A\s*</) ? "erb" : "ruby"
      end

      def erb_findings(source, path)
        audit = Audit.new(root: @root, output: StringIO.new)
        a11y = A11yAudit.new(root: @root, output: StringIO.new)
        categories = audit.categories(audit.scan_source(path, source)) + a11y.categories(a11y.scan_source(path, source))
        drift = categories.flat_map(&:findings).map do |finding|
          { "rule" => finding.category, "severity" => finding.severity.to_s, "line" => finding.location&.line,
            "message" => finding.title, "fix" => finding.suggestion }
        end
        drift + erb_ruby_fragments(source).flat_map { |code, line| component_calls(code, line) }
      end

      def ruby_findings(source)
        result = Prism.parse(source)
        if result.failure?
          error = result.errors.first
          return [{ "rule" => "ruby_syntax", "severity" => "error", "line" => error.location.start_line,
                    "message" => "Ruby doesn't parse: #{error.message}", "fix" => nil }]
        end
        component_calls(source, 1)
      end

      # The Ruby in each ERB tag, with the line it starts on. A block
      # opener (`render X.new do`) is closed so it parses; a fragment
      # that still doesn't (`if x`) is skipped.
      def erb_ruby_fragments(source)
        document = ErbParser.parse(source).document
        ErbParser.each_node(document).filter_map do |node|
          next unless node.respond_to?(:tag_opening) && node.respond_to?(:content) && node.content
          next if node.tag_opening.value.start_with?("<%#")

          [node.content.value, node.location.start.line]
        end
      end

      def component_calls(code, first_line)
        tree = [code, "#{code}\nend"].map { |text| Prism.parse(text) }.find(&:success?)
        return [] unless tree

        findings = []
        each_node(tree.value) do |node|
          next unless node.is_a?(Prism::CallNode) && node.name == :new && constant?(node.receiver)

          findings.concat(check_call(node, first_line + node.location.start_line - 1))
        end
        findings
      end

      def check_call(call, line)
        written = RubySource.constant_name(call.receiver)
        return [] unless written

        component = resolve(written)
        unless component
          return [] unless written.end_with?("Component") || written.start_with?("Components::")

          return [finding("unknown_component", line, "#{written} isn't one of this app's components.",
                          "Use one of: #{closest(written).join(", ")} (see list_components).")]
        end

        params = Array(component["params"])
        return [] if params.empty? # no initialize found, so nothing to check against

        args = call.arguments&.arguments || []
        hash = args.last.is_a?(Prism::KeywordHashNode) ? args.last : nil
        positional = hash ? args[0...-1] : args
        return [] if args.any? { |arg| arg.is_a?(Prism::SplatNode) } || hash&.elements&.any?(Prism::AssocSplatNode)

        name = component["name"]
        keywords = hash ? hash.elements.filter_map { |el| el.key.unescaped if el.key.is_a?(Prism::SymbolNode) } : []
        findings = []
        known = params.select { |p| p["kind"] == "keyword" }.map { |p| p["name"] }
        keyrest = params.find { |p| p["kind"] == "keyrest" }
        (keywords - known).each do |keyword|
          near = known.find { |k| distance(k, keyword) <= 2 && !keywords.include?(k) }
          if keyrest.nil?
            findings << finding("unknown_param", line, "#{name}.new doesn't take `#{keyword}:`.",
                                near ? "Did you mean `#{near}:`? It takes #{signature(params)}." : "It takes #{signature(params)}.")
          elsif near
            # Taken by **options, but most likely a typo.
            findings << finding("unknown_param", line, "`#{keyword}:` goes into #{name}'s **#{keyrest["name"]}, not a param.",
                                "Did you mean `#{near}:`? It takes #{signature(params)}.").merge("severity" => "warning")
          end
        end
        params.select { |p| p["kind"] == "keyword" && p["required"] && !keywords.include?(p["name"]) }.each do |param|
          findings << finding("missing_param", line, "#{name}.new needs `#{param["name"]}:`.", "It takes #{signature(params)}.")
        end
        positional_params = params.select { |p| p["kind"] == "positional" }
        required = positional_params.count { |p| p["required"] }
        unless params.any? { |p| p["kind"] == "rest" }
          if positional.length > positional_params.length
            findings << finding("wrong_arguments", line, "#{name}.new takes #{positional_params.length} positional " \
                                                         "argument#{"s" unless positional_params.length == 1}, " \
                                                         "not #{positional.length}.", "It takes #{signature(params)}.")
          end
        end
        if positional.length < required
          findings << finding("wrong_arguments", line, "#{name}.new needs #{required} positional argument" \
                                                       "#{"s" unless required == 1}, not #{positional.length}.",
                              "It takes #{signature(params)}.")
        end
        findings
      end

      def finding(rule, line, message, fix)
        { "rule" => rule, "severity" => "error", "line" => line, "message" => message, "fix" => fix }
      end

      # The component written here: its full name, or the last part of
      # one when only one component has it (`BadgeComponent` inside
      # `module Admin`).
      def resolve(written)
        exact = @components.find { |c| c["name"] == written }
        return exact if exact

        tail = @components.select { |c| c["name"].split("::").last == written.split("::").last }
        tail.first if tail.length == 1
      end

      def closest(written)
        target = written.split("::").last.downcase
        @components.map { |c| c["name"] }
                   .min_by(3) { |name| [distance(name.split("::").last.downcase, target), name] }
      end

      def signature(params)
        parts = params.map do |p|
          case p["kind"]
          when "keyword" then p["required"] ? "#{p["name"]}:" : "#{p["name"]}: #{p["default"]}"
          when "positional" then p["required"] ? p["name"] : "#{p["name"]} = #{p["default"]}"
          when "rest" then "*#{p["name"]}"
          when "keyrest" then "**#{p["name"]}"
          else "&#{p["name"]}"
          end
        end
        "(#{parts.join(", ")})"
      end

      def constant?(node)
        node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      end

      def each_node(node, &block)
        yield node
        node.compact_child_nodes.each { |child| each_node(child, &block) }
      end

      def distance(a, b)
        previous = (0..b.length).to_a
        a.each_char.with_index(1) do |char_a, i|
          current = [i]
          b.each_char.with_index(1) do |char_b, j|
            current << [previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (char_a == char_b ? 0 : 1)].min
          end
          previous = current
        end
        previous.last
      end
    end
  end
end
