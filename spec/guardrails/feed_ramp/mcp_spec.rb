# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "guardrails/feed_ramp/mcp"

RSpec.describe Guardrails::FeedRamp::MCP do
  let(:fixture) { Pathname(File.expand_path("../../fixtures/feed_ramp_app", __dir__)) }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      FileUtils.cp_r("#{fixture}/.", @root)
      example.run
    end
  end

  let(:log) { StringIO.new }
  let(:library) { Guardrails::FeedRamp::MCP::Library.new(root: @root, log: log) }
  let(:server) { Guardrails::FeedRamp::MCP::Server.new(library: library, log: log) }

  def request(method, params = nil, id: 1)
    server.handle({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }.compact)
  end

  def call_tool(name, arguments = {})
    request("tools/call", { "name" => name, "arguments" => arguments })["result"]
  end

  def tool_data(name, arguments = {})
    result = call_tool(name, arguments)
    expect(result["isError"]).to be(false), result.dig("content", 0, "text")
    JSON.parse(result.dig("content", 0, "text"))
  end

  describe "the protocol" do
    it "answers initialize with the client's protocol version when it knows it, and its tools" do
      result = request("initialize", { "protocolVersion" => "2025-03-26", "capabilities" => {} })["result"]
      expect(result).to include("protocolVersion" => "2025-03-26", "capabilities" => { "tools" => {} },
                                "serverInfo" => { "name" => "ui_guardrails", "version" => Guardrails::VERSION })
      expect(request("initialize", { "protocolVersion" => "1999-01-01" })["result"]["protocolVersion"]).to eq("2025-06-18")
    end

    it "lists four tools, each with an object input schema" do
      tools = request("tools/list")["result"]["tools"]
      expect(tools.map { |t| t["name"] }).to eq(%w[list_components get_component search_components check_snippet])
      expect(tools.map { |t| t.dig("inputSchema", "type") }.uniq).to eq(["object"])
    end

    it "never answers a notification, and answers ping" do
      expect(server.handle({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })).to be_nil
      expect(server.handle({ "jsonrpc" => "2.0", "method" => "tools/list" })).to be_nil
      expect(request("ping")).to eq("jsonrpc" => "2.0", "id" => 1, "result" => {})
    end

    it "gives JSON-RPC errors for bad input" do
      expect(server.handle_line("not json")).to include("id" => nil, "error" => include("code" => -32_700))
      expect(server.handle({ "id" => 3 })).to include("id" => 3, "error" => include("code" => -32_600))
      expect(request("resources/list")["error"]).to include("code" => -32_601, "message" => "Method not found: resources/list")
      expect(request("tools/call", { "name" => "nope" })["error"]).to include("code" => -32_602)
      expect(request("tools/call", { "name" => "get_component", "arguments" => {} })["error"])
        .to include("code" => -32_602, "message" => "Missing required argument: name")
    end

    it "serves line by line until the input closes, writing one JSON object per line" do
      input = StringIO.new(<<~JSONL)
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}

        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_components","arguments":{}}}
      JSONL
      output = StringIO.new
      Guardrails::FeedRamp::MCP::Server.new(library: library, input: input, output: output, log: log).run

      lines = output.string.lines
      expect(lines.length).to eq(2)
      expect(lines.map { |line| JSON.parse(line)["id"] }).to eq([1, 2])
    end
  end

  describe "list_components" do
    it "gives each component in brief, and the tokens by category" do
      data = tool_data("list_components")
      expect(data["components"].map { |c| c["name"] }).to include("ButtonComponent", "Components::Alert")
      expect(data["components"].find { |c| c["name"] == "ButtonComponent" }).to eq(
        "name" => "ButtonComponent", "kind" => "view_component", "description" => "The app's button.",
        "params" => ["label:", "variant:", "size:", "html_options"], "slots" => ["icon"], "has_example" => true
      )
      expect(data["tokens"]["color"]).to include("--color-brand")
    end
  end

  describe "get_component" do
    it "gives the full manifest entry, found by full name, any case, or short name" do
      expect(tool_data("get_component", "name" => "ButtonComponent")).to include("params", "slots", "previews", "example")
      expect(tool_data("get_component", "name" => "buttoncomponent")["name"]).to eq("ButtonComponent")
      expect(tool_data("get_component", "name" => "Badge")["name"]).to eq("Admin::BadgeComponent")
      expect(tool_data("get_component", "name" => "Alert")["name"]).to eq("Components::Alert")
    end

    it "is a tool error naming the components when there's no such one" do
      result = call_tool("get_component", "name" => "Modal")
      expect(result["isError"]).to be true
      expect(result.dig("content", 0, "text")).to start_with("No component named Modal. Components: ")
    end
  end

  describe "search_components" do
    it "ranks components by name, then description, params, slots and previews" do
      expect(tool_data("search_components", "query" => "button").first["name"]).to eq("ButtonComponent")
      expect(tool_data("search_components", "query" => "admin nav count").map { |c| c["name"] }.first).to eq("Admin::BadgeComponent")
      expect(tool_data("search_components", "query" => "header actions").map { |c| c["name"] }).to include("CardComponent")
    end

    it "is a tool error when nothing matches" do
      result = call_tool("search_components", "query" => "carousel")
      expect(result["isError"]).to be true
      expect(result.dig("content", 0, "text")).to include("No component matches \"carousel\"")
    end
  end

  describe "check_snippet" do
    it "reports drift and component API mistakes in ERB" do
      data = tool_data("check_snippet", "source" => %(<p style="margin: 0">\n<%= render ButtonComponent.new(size: :lg) %>\n</p>\n))
      expect(data).to include("language" => "erb", "ok" => false)
      expect(data["findings"].map { |f| [f["rule"], f["line"]] }).to eq([["inline_style", 1], ["missing_param", 2]])
    end

    it "is ok for a clean snippet" do
      data = tool_data("check_snippet", "source" => %(<%= render ButtonComponent.new(label: "Save") %>\n))
      expect(data).to include("ok" => true, "findings" => [])
    end

    it "is a tool error for a language it doesn't know" do
      result = call_tool("check_snippet", "source" => "x", "language" => "haml")
      expect(result["isError"]).to be true
    end
  end

  describe Guardrails::FeedRamp::MCP::Library do
    it "writes the manifest when it's missing or stale, and keeps it fresh as components change" do
      expect(library.names).to include("ButtonComponent")
      expect(@root.join(".ui_guardrails/manifest.json")).to exist
      expect(log.string).to include("created .ui_guardrails/manifest.json")

      FileUtils.mkdir_p(@root.join("app/components"))
      @root.join("app/components/modal_component.rb").write("class ModalComponent < ApplicationComponent\n  def call; end\nend\n")
      expect(library.names).to include("ModalComponent")
      expect(JSON.parse(@root.join(".ui_guardrails/manifest.json").read)["components"].map { |c| c["name"] }).to include("ModalComponent")

      @root.join("app/components/tooltip_component.rb").delete
      expect(library.names).not_to include("TooltipComponent")
    end

    it "leaves the files alone with write: false" do
      quiet = described_class.new(root: @root, write: false, log: log)
      expect(quiet.names).to include("ButtonComponent")
      expect(@root.join(".ui_guardrails")).not_to exist
    end
  end

  describe "the ui_guardrails-mcp executable" do
    let(:exe) { File.expand_path("../../../exe/ui_guardrails-mcp", __dir__) }
    let(:lib) { File.expand_path("../../../lib", __dir__) }

    it "speaks only protocol on stdout" do
      input = [
        { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => { "protocolVersion" => "2025-06-18" } },
        { "jsonrpc" => "2.0", "method" => "notifications/initialized" },
        { "jsonrpc" => "2.0", "id" => 2, "method" => "tools/list" },
        { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
          "params" => { "name" => "check_snippet", "arguments" => { "source" => "<img src='a.png'>" } } }
      ].map { |message| JSON.generate(message) }.join("\n")

      out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, exe, "--root", @root.to_s, stdin_data: "#{input}\n")

      expect(status).to be_success, err
      messages = out.lines.map { |line| JSON.parse(line) }
      expect(messages.map { |m| m["id"] }).to eq([1, 2, 3])
      expect(JSON.parse(messages.last.dig("result", "content", 0, "text"))["findings"].map { |f| f["rule"] }).to eq(["a11y (static)"])
    end
  end
end
