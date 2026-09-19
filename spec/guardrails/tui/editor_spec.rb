# frozen_string_literal: true

require "guardrails/report/finding"
require "guardrails/tui/editor"

RSpec.describe Guardrails::TUI::Editor do
  let(:location) { Guardrails::Report::Location.new(file: "app/views/home.html.erb", line: 7, column: 12) }
  let(:file_only) { Guardrails::Report::Location.new(file: "app/views/home.html.erb") }
  let(:path) { "/srv/app/app/views/home.html.erb" }

  def command(editor, loc = location, **env)
    described_class.command(loc, root: "/srv/app", env: { "EDITOR" => editor }.merge(env))
  end

  it "uses --goto file:line:column for VS Code-family editors" do
    expect(command("code")).to eq(["code", "--goto", "#{path}:7:12"])
    expect(command("cursor")).to eq(["cursor", "--goto", "#{path}:7:12"])
  end

  it "drops --wait, which would freeze the TUI until the tab closes" do
    expect(command("code --wait")).to eq(["code", "--goto", "#{path}:7:12"])
    expect(command("subl -w")).to eq(["subl", "#{path}:7:12"])
  end

  it "uses +line for terminal editors" do
    expect(command("vim")).to eq(["vim", "+7", path])
    expect(command("nvim")).to eq(["nvim", "+7", path])
    expect(command("nano")).to eq(["nano", "+7", path])
  end

  it "uses file:line:column for Zed, Sublime, and Helix" do
    expect(command("zed")).to eq(["zed", "#{path}:7:12"])
    expect(command("hx")).to eq(["hx", "#{path}:7:12"])
  end

  it "uses -l for TextMate and --line for JetBrains" do
    expect(command("mate")).to eq(["mate", "-l", "7", path])
    expect(command("rubymine")).to eq(["rubymine", "--line", "7", path])
  end

  it "passes just the path to editors it doesn't know" do
    expect(command("my-editor --flag")).to eq(["my-editor", "--flag", path])
  end

  it "omits position arguments for file-level locations" do
    expect(command("vim", file_only)).to eq(["vim", path])
    expect(command("code", file_only)).to eq(["code", "--goto", path])
  end

  it "resolves editors given by full path" do
    expect(command("/usr/local/bin/code -n")).to eq(["/usr/local/bin/code", "-n", "--goto", "#{path}:7:12"])
  end

  it "prefers GUARDRAILS_EDITOR, then VISUAL, then EDITOR" do
    expect(command("nano", location, "VISUAL" => "vim").first).to eq("vim")
    expect(command("nano", location, "VISUAL" => "vim", "GUARDRAILS_EDITOR" => "zed").first).to eq("zed")
    expect(command("nano", location, "VISUAL" => "  ").first).to eq("nano")
  end

  it "falls back to the OS opener when no editor is configured" do
    expect(described_class.command(location, root: "/srv/app", env: {}, host_os: "darwin24")).to eq(["open", path])
    expect(described_class.command(location, root: "/srv/app", env: {}, host_os: "linux-gnu")).to eq(["xdg-open", path])
    expect(described_class.command(location, root: "/srv/app", env: {}, host_os: "mswin")).to be_nil
  end

  it "never produces a shell string, so odd filenames stay inert" do
    hostile = Guardrails::Report::Location.new(file: "app/views/$(rm -rf ~);.erb", line: 1)

    expect(command("vim", hostile)).to eq(["vim", "+1", "/srv/app/app/views/$(rm -rf ~);.erb"])
  end

  it "knows which editors need the terminal handed over" do
    expect(described_class.terminal?(["vim", "+7", path])).to be(true)
    expect(described_class.terminal?(["/usr/bin/nvim", path])).to be(true)
    expect(described_class.terminal?(["code", "--goto", path])).to be(false)
  end
end
