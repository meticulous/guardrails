# frozen_string_literal: true

namespace :ui_guardrails do
  desc "Initialize Guardrails configuration and analyze stylesheet stack (FORCE=1 to overwrite existing config)"
  task :init do
    require "guardrails/init"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    force = %w[1 true yes].include?(ENV["FORCE"]&.downcase)
    Guardrails::Init.new(root: root, force: force).run
  end

  desc "Audit views and components for UI drift (SUGGEST=1, APPLY=1, FORMAT=json|html, SEVERITY=error|warning)"
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
    run = begin
      Guardrails::Report::Run.from_env(root: root, style: report_style).call
    rescue ArgumentError => e
      abort e.message
    end

    if format == :json
      require "json"
      $stdout.puts JSON.pretty_generate(run.to_h)
    elsif format == :html
      # One self-contained file — for a browser, a PR attachment, or a
      # CI artifact. OUTPUT= overrides the default tmp/ location.
      require "guardrails/report/html"
      output = ENV["OUTPUT"].to_s.strip
      path = Guardrails::Report::Html.new(categories: run.categories, root: root, muted: run.muted_severities)
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
      # A filtered run that prints "no violations found" must not read
      # as a clean bill of health.
      unless run.muted_severities.empty?
        muted = run.muted_severities.map { |s| "#{s}s" }.join(" and ")
        $stdout.puts ""
        $stdout.puts report_style.colorize("SEVERITY=#{run.min_severity} — #{muted} were not checked.", :dim)
      end
    end

    exit 1 if run.failing?
  end

  desc "Browse audit findings interactively (same env options as ui_guardrails:audit)"
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
    rescue Guardrails::TUI::NotInteractive, ArgumentError => e
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

  desc "Generate SVG icon sprite and audit icon usage (SUGGEST=1, FORMAT=json) — exits 1 on inline SVGs, unknown icon refs, or emoji/glyph icons"
  task :icons do
    require "guardrails/icons"
    require "stringio"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    suggest = %w[1 true yes].include?(ENV["SUGGEST"]&.downcase)
    format = ENV["FORMAT"].to_s.downcase == "json" ? :json : :text

    if format == :json
      # Suppress human-readable output; only JSON goes to stdout.
      require "json"
      result = Guardrails::Icons.new(root: root, output: StringIO.new,
                                     suggest: suggest, format: :json).run
      $stdout.puts JSON.pretty_generate(result.to_h)
    else
      result = Guardrails::Icons.new(root: root, suggest: suggest).run
    end

    exit 1 if result.violations?
  end

  desc "Audit design tokens and report drift"
  task :tokens do
    require "guardrails/tokens"
    root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
    Guardrails::Tokens.new(root: root).run
  end

  namespace :feed_ramp do
    desc "Write the component manifest for coding agents: .ui_guardrails/manifest.json + COMPONENTS.md (CHECK=1 exits 1 when they're out of date, writing nothing)"
    task :manifest do
      require "guardrails/feed_ramp"
      root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
      manifest = Guardrails::FeedRamp::Manifest.new(root: root)

      if %w[1 true yes].include?(ENV["CHECK"]&.downcase)
        abort "Feed Ramp manifest is out of date; run `rake ui_guardrails:feed_ramp:manifest` and commit the result." if manifest.stale?
        puts "Feed Ramp manifest is up to date."
        next
      end

      data = manifest.to_h
      manifest.write.each do |path, status|
        puts "#{status.to_s.capitalize}: #{path.relative_path_from(root)}"
      end
      libraries = data["libraries"].select { |_name, version| version }.map { |name, version| "#{name} #{version}" }
      puts "#{data["components"].length} components, #{data["tokens"].length} tokens" \
           "#{libraries.empty? ? "" : " (#{libraries.join(", ")})"}."
    end

    desc "Write the manifest, then point coding agents at it: a managed block in CLAUDE.md and AGENTS.md, " \
         "and .cursor/rules/ui-guardrails.mdc (TARGETS=claude,agents,cursor,gemini,copilot; CHECK=1; REMOVE=1)"
    task :rules do
      require "guardrails/feed_ramp"
      root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
      manifest = Guardrails::FeedRamp::Manifest.new(root: root)
      targets = ENV["TARGETS"].to_s.split(",").map(&:strip).reject(&:empty?)
      describe = lambda do |change|
        line = "#{change.status.to_s.capitalize}: #{change.path.relative_path_from(root)}"
        change.reason ? "#{line} (#{change.reason})" : line
      end

      begin
        rules = Guardrails::FeedRamp::AgentRules.for(manifest, targets: targets.empty? ? nil : targets)

        if %w[1 true yes].include?(ENV["REMOVE"]&.downcase)
          rules.remove.each { |change| puts describe.call(change) }
          next
        end

        if %w[1 true yes].include?(ENV["CHECK"]&.downcase)
          stale = rules.stale.map { |change| change.path.relative_path_from(root).to_s }
          stale.unshift(manifest.path.relative_path_from(root).to_s) if manifest.stale?
          abort "Feed Ramp files are out of date (#{stale.join(", ")}); run `rake ui_guardrails:feed_ramp:rules` and commit the result." if stale.any?
          puts "Feed Ramp manifest and agent rules are up to date."
          next
        end

        rules.stale # a target with broken markers stops the run before anything is written
        manifest.write.each { |path, status| puts "#{status.to_s.capitalize}: #{path.relative_path_from(root)}" }
        rules.write.each { |change| puts describe.call(change) }
      rescue Guardrails::Error => e
        abort e.message
      end
    end
  end

  namespace :hooks do
    desc "Add Guardrails to coding agents' hooks (AGENT=claude,codex,cursor,gemini or all; default claude)"
    task :install do
      require "guardrails/hooks/installer"
      root = defined?(Rails) ? Rails.root : Pathname(Dir.pwd)
      agents = ENV.fetch("AGENT", "claude").split(",").map(&:strip).reject(&:empty?)
      agents = Guardrails::Hooks::Adapters::ALL.keys if agents == ["all"]

      begin
        changes = Guardrails::Hooks::Installer.new(root: root, agents: agents).call
      rescue Guardrails::Error => e
        abort e.message
      end

      changes.each do |change|
        puts "#{change.changed ? "Added hooks to" : "Already set up:"} #{change.path} (#{change.agent})"
      end
      agents = changes.map(&:agent)
      puts "Codex runs project hooks once you trust them in /hooks." if agents.include?("codex")
      puts "Cursor and Gemini CLI run project hooks in trusted folders only." if agents.intersect?(%w[cursor gemini])
    end
  end
end
