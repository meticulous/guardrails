# frozen_string_literal: true

namespace :guardrails do
  desc "Initialize Guardrails configuration and analyze stylesheet stack (FORCE=1 to overwrite existing config)"
  task :init do
    require "guardrails/init"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    force = %w[1 true yes].include?(ENV["FORCE"]&.downcase)
    Guardrails::Init.new(root: root, force: force).run
  end

  desc "Audit views and components for UI drift (SUGGEST=1, APPLY=1, FORMAT=json|html)"
  task :audit do
    require "guardrails/report/run"
    require "guardrails/report/style"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)

    format = { "json" => :json, "html" => :html }.fetch(ENV["FORMAT"].to_s.downcase, :text)

    # One Style bound to the real terminal, threaded through every
    # detector so the whole report tracks the same TTY/NO_COLOR signal
    # (see Report::Run). JSON and HTML modes discard the report body,
    # so they run unstyled.
    report_style = format == :text ? Guardrails::Report::Style.new(io: $stdout) : nil
    run = Guardrails::Report::Run.from_env(root: root, style: report_style).call

    if format == :json
      require "json"
      $stdout.puts JSON.pretty_generate(run.to_h)
    elsif format == :html
      # One self-contained file — for a browser, a PR attachment, or a
      # CI artifact. OUTPUT= overrides the default tmp/ location.
      require "guardrails/report/html"
      output = ENV["OUTPUT"].to_s.strip
      path = Guardrails::Report::Html.new(categories: run.categories, root: root)
                                     .write(output.empty? ? Guardrails::Report::Html::DEFAULT_PATH : output)
      $stdout.puts "Guardrails audit: #{run.findings.length} findings → #{path}"
    else
      # Render the summary twice — once at the top so the reader
      # knows what to expect, once at the bottom as a recap so they
      # don't have to scroll back up after the per-detector dump.
      # On a long output (Patchvault has 981 findings) the bottom
      # recap is the load-bearing one.
      summary = Guardrails::Report::Summary.new(entries: run.summary_entries, output: $stdout, style: report_style)
      summary.render
      $stdout.write run.body
      summary.render(recap: true)
    end

    exit 1 if run.failing?
  end

  desc "Browse audit findings interactively (same env options as guardrails:audit)"
  task :tui do
    require "guardrails/report/run"
    require "guardrails/tui"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)

    # APPLY / SUGGEST are deliberately not honored here: browsing
    # shouldn't rewrite views or drop markdown files, least of all
    # again on every `r` re-run.
    env = ENV.to_h.reject { |key, _| %w[APPLY SUGGEST].include?(key) }
    runner = -> { Guardrails::Report::Run.from_env(root: root, env: env).call }
    begin
      Guardrails::TUI.new(runner: runner, root: root).start
    rescue Guardrails::TUI::NotInteractive => e
      abort e.message
    end
  end

  desc "Parse axe-core JSON output and report deep a11y findings (AXE_JSON=path/to/axe.json)"
  task :"a11y:deep" do
    require "guardrails/a11y_deep"
    path = ENV["AXE_JSON"] or abort "Set AXE_JSON=path/to/axe.json (output from `npx @axe-core/cli ... --save`)"
    runner = Guardrails::A11yDeep.new(input: path)
    findings = runner.run
    exit 1 if runner.any_failing?(findings)
  end

  desc "Consume screenshot-diff output and report visual regressions (VISUAL_DIFF_DIR=..., VISUAL_DIFF_THRESHOLD=0.0)"
  task :"visual:deep" do
    require "guardrails/visual_diff"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    # The standalone task implies the user is opting in regardless of
    # Configuration; flip enabled on so a no-config sidecar run works.
    Guardrails.configure { |c| c.visual_diff.enabled = true }
    # Same blank-env guard as the main audit task — see note there.
    if (dir = ENV["VISUAL_DIFF_DIR"]) && !dir.strip.empty?
      Guardrails.configure { |c| c.visual_diff.snap_diff_dir = dir.strip }
    end
    if (thr = ENV["VISUAL_DIFF_THRESHOLD"]) && !thr.strip.empty?
      Guardrails.configure { |c| c.visual_diff.threshold = thr.strip }
    end
    runner = Guardrails::VisualDiff.new(root: root)
    findings = runner.run
    exit 1 if runner.any_failing?(findings)
  end

  desc "Generate SVG icon sprite and audit icon usage"
  task :icons do
    require "guardrails/icons"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    Guardrails::Icons.new(root: root).run
  end

  desc "Audit design tokens and report drift"
  task :tokens do
    require "guardrails/tokens"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    Guardrails::Tokens.new(root: root).run
  end
end
