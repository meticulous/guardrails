# frozen_string_literal: true

require "json"
require "pathname"
require_relative "../version"
require_relative "../tokens"
require_relative "manifest"
require_relative "snippet_check"

module Guardrails
  module FeedRamp
    # The Feed Ramp MCP server: the manifest as tools a coding agent can
    # call while it works. `ui_guardrails-mcp` runs it over stdio.
    module MCP
      # The manifest, kept fresh: rebuilt whenever a file it's read from
      # is added, removed or changed, and written to disk when that
      # changes it, so the audit's component_match sees the same
      # components the tools offer.
      class Library
        WATCHED_DIRS = %w[app/views app/assets/stylesheets app/assets/tailwind].freeze
        WATCHED_FILES = %w[guardrails.yml Gemfile.lock tailwind.config.js config/tailwind.config.js].freeze
        SEARCH_LIMIT = 10

        attr_reader :root

        def initialize(root:, write: true, log: $stderr)
          @root = Pathname(root).expand_path
          @write = write
          @log = log
        end

        def manifest
          refresh
          @data
        end

        def list
          {
            "components" => manifest["components"].map { |component| summary(component) },
            "tokens" => manifest["tokens"].group_by { |t| t["category"] }.sort.to_h { |category, list| [category, list.map { |t| t["name"] }] },
            "details" => "get_component(name) gives a component's params, slots, previews and a usage example to copy."
          }
        end

        # The component, or nil.
        def get(name)
          query = name.to_s.strip.delete_prefix("::")
          components = manifest["components"]
          components.find { |c| c["name"] == query } ||
            unique(components.select { |c| c["name"].casecmp?(query) }) ||
            unique(components.select { |c| [query, "#{query}Component"].any? { |q| c["name"].split("::").last.casecmp?(q) } })
        end

        def names
          manifest["components"].map { |c| c["name"] }
        end

        def search(query)
          words = terms(query)
          return [] if words.empty?

          scored = manifest["components"].filter_map do |component|
            score = words.sum { |word| score(component, word) }
            [component, score] if score.positive?
          end
          scored.sort_by { |component, score| [-score, component["name"]] }.first(SEARCH_LIMIT).map { |c, _| summary(c) }
        end

        def check(source, language: nil, path: nil)
          SnippetCheck.new(root: @root, manifest: manifest).call(source, language: language, path: path)
        end

        private

        def refresh
          stamp = fingerprint
          return if stamp == @stamp

          built = Manifest.new(root: @root)
          @data = built.to_h
          @stamp = stamp
          return unless @write

          built.write.each do |path, status|
            @log.puts "ui_guardrails-mcp: #{status} #{path.relative_path_from(@root)}" unless status == :unchanged
          end
        end

        # Every file the manifest is read from, with its mtime: a new,
        # deleted or edited one changes it.
        def fingerprint
          config = Config.load(@root)
          dirs = (config.component_paths + config.preview_paths + WATCHED_DIRS).uniq
          files = dirs.flat_map { |dir| Dir.glob(@root.join(dir, "**/*").to_s) } +
                  (WATCHED_FILES + config.token_files).map { |file| @root.join(file).to_s }
          files.uniq.sort.filter_map { |file| [file, File.mtime(file).to_f] if File.file?(file) }.hash
        end

        def unique(list)
          list.first if list.length == 1
        end

        def summary(component)
          {
            "name" => component["name"],
            "kind" => component["kind"],
            "description" => component["description"]&.split(/(?<=[.!?])\s+/)&.first,
            "params" => Array(component["params"]).map { |p| p["kind"] == "keyword" ? "#{p["name"]}:" : p["name"] },
            "slots" => Array(component["slots"]).map { |s| s["name"] },
            "has_example" => !component["example"].nil?
          }
        end

        # Lowercase words, with CamelCase and snake_case split apart.
        def terms(text)
          text.to_s.gsub(/([a-z\d])([A-Z])/, '\1 \2').downcase.scan(/[a-z\d]+/).reject { |w| w.length < 2 } - %w[component]
        end

        def score(component, word)
          fields = {
            terms(component["name"]) => 5,
            terms(component["description"]) => 2,
            Array(component["params"]).flat_map { |p| terms(p["name"]) + terms(p["description"]) } => 1,
            Array(component["slots"]).flat_map { |s| terms(s["name"]) } => 1,
            Array(component["previews"]).flat_map { |p| terms(p["name"]) + terms(p["label"]) + terms(p["description"]) } => 1
          }
          fields.sum do |words, weight|
            if words.include?(word) then weight * 2
            elsif words.any? { |w| w.start_with?(word) || word.start_with?(w) && w.length >= 3 } then weight
            else 0
            end
          end
        end
      end

      # JSON-RPC 2.0 over stdio, one message per line, as the Model Context
      # Protocol's stdio transport has it. Nothing but protocol messages
      # may reach `output`; logging goes to `log`.
      class Server
        PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze

        PARSE_ERROR = -32_700
        INVALID_REQUEST = -32_600
        METHOD_NOT_FOUND = -32_601
        INVALID_PARAMS = -32_602
        INTERNAL_ERROR = -32_603

        TOOLS = [
          {
            "name" => "list_components",
            "description" => "List this app's UI components (ViewComponent / Phlex) and design tokens. Call this before " \
                             "writing any view markup, and render an existing component instead of hand-writing HTML.",
            "inputSchema" => { "type" => "object", "properties" => {} }
          },
          {
            "name" => "get_component",
            "description" => "Everything about one component: constructor params with defaults, slots, preview " \
                             "variants and a real usage example from the app to copy.",
            "inputSchema" => {
              "type" => "object",
              "properties" => { "name" => { "type" => "string", "description" => "e.g. ButtonComponent, Admin::BadgeComponent, or Button" } },
              "required" => ["name"]
            }
          },
          {
            "name" => "search_components",
            "description" => "Find components by what they're for (\"button\", \"modal dialog\", \"empty state\"), " \
                             "searching names, descriptions, params, slots and previews.",
            "inputSchema" => {
              "type" => "object",
              "properties" => { "query" => { "type" => "string" } },
              "required" => ["query"]
            }
          },
          {
            "name" => "check_snippet",
            "description" => "Check ERB or Ruby (Phlex) you're about to write: UI drift (raw colours, inline styles, " \
                             "markup copying a component), static a11y, and component calls with unknown components, " \
                             "params they don't take, or required params left out. Fix what it reports before writing the file.",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "source" => { "type" => "string", "description" => "The ERB or Ruby to check" },
                "language" => { "type" => "string", "enum" => %w[erb ruby], "description" => "Guessed from the source when left out" },
                "path" => { "type" => "string", "description" => "Where it will live, e.g. app/views/posts/show.html.erb" }
              },
              "required" => ["source"]
            }
          }
        ].freeze

        def initialize(library:, input: $stdin, output: $stdout, log: $stderr)
          @library = library
          @input = input
          @output = output
          @log = log
        end

        # Serves until the input closes.
        def run
          @input.each_line do |line|
            next if line.strip.empty?

            response = handle_line(line)
            write(response) if response
          end
        rescue Errno::EPIPE, IOError
          nil
        end

        # The response to one line, or nil for a notification.
        def handle_line(line)
          message = JSON.parse(line)
        rescue JSON::ParserError => e
          error_response(nil, PARSE_ERROR, "Parse error: #{e.message.lines.first.strip}")
        else
          handle(message)
        end

        def handle(message)
          unless message.is_a?(Hash) && message["jsonrpc"] == "2.0" && message["method"].is_a?(String)
            return error_response(message.is_a?(Hash) ? message["id"] : nil, INVALID_REQUEST, "Invalid request")
          end

          id = message["id"]
          notification = !message.key?("id")
          result = dispatch(message["method"], message["params"] || {})
          notification ? nil : { "jsonrpc" => "2.0", "id" => id, "result" => result }
        rescue RPCError => e
          notification ? nil : error_response(id, e.code, e.message)
        rescue StandardError, ScriptError => e
          @log.puts "ui_guardrails-mcp: #{e.class}: #{e.message}"
          notification ? nil : error_response(id, INTERNAL_ERROR, "#{e.class}: #{e.message}")
        end

        private

        class RPCError < StandardError
          attr_reader :code

          def initialize(code, message)
            super(message)
            @code = code
          end
        end

        def dispatch(method, params)
          case method
          when "initialize" then initialize_result(params)
          when "ping" then {}
          when "tools/list" then { "tools" => TOOLS }
          when "tools/call" then call_tool(params["name"], params["arguments"] || {})
          when %r{\Anotifications/} then nil
          else raise RPCError.new(METHOD_NOT_FOUND, "Method not found: #{method}")
          end
        end

        def initialize_result(params)
          requested = params["protocolVersion"]
          {
            "protocolVersion" => PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first,
            "capabilities" => { "tools" => {} },
            "serverInfo" => { "name" => "ui_guardrails", "version" => VERSION },
            "instructions" => "This app's UI component library. Before writing view markup, search_components or " \
                              "list_components and render what exists; check_snippet before writing the file."
          }
        end

        def call_tool(name, arguments)
          raise RPCError.new(INVALID_PARAMS, "arguments must be an object") unless arguments.is_a?(Hash)

          case name
          when "list_components" then text(@library.list)
          when "get_component"
            component_name = required(arguments, "name")
            component = @library.get(component_name)
            return text(component) if component

            names = @library.names
            closest = names.min_by(5) { |n| [n.downcase.include?(component_name.downcase) ? 0 : 1, n] }
            tool_error("No component named #{component_name}. Components: #{closest.join(", ")}" \
                       "#{names.length > 5 ? " (and #{names.length - 5} more; list_components shows all)" : ""}.")
          when "search_components"
            found = @library.search(required(arguments, "query"))
            return text(found) if found.any?

            tool_error("No component matches #{arguments["query"].inspect}. list_components shows all " \
                       "#{@library.names.length}; if none fits, a new one may be needed.")
          when "check_snippet"
            text(@library.check(required(arguments, "source"), language: arguments["language"], path: arguments["path"]))
          else
            raise RPCError.new(INVALID_PARAMS, "Unknown tool: #{name}")
          end
        rescue ArgumentError => e
          tool_error(e.message)
        end

        def required(arguments, key)
          value = arguments[key]
          raise RPCError.new(INVALID_PARAMS, "Missing required argument: #{key}") unless value.is_a?(String) && !value.empty?

          value
        end

        def text(data)
          { "content" => [{ "type" => "text", "text" => JSON.pretty_generate(data) }], "isError" => false }
        end

        def tool_error(message)
          { "content" => [{ "type" => "text", "text" => message }], "isError" => true }
        end

        def error_response(id, code, message)
          { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
        end

        def write(response)
          @output.write("#{JSON.generate(response)}\n")
          @output.flush
        end
      end
    end
  end
end
