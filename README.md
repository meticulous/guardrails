# UI-Guardrails

A Rails toolset that prevents UI drift in AI-assisted applications. Static audits over your views, components, stylesheets, JS controllers, and tokens — surfacing the kinds of inconsistencies that compound silently as an AI assistant ships code faster than design-system discipline can keep up.

Built and maintained by [Meticulous](https://meticulous.com).

**Current release:** 2.0.0, which adds [Feed Ramp](#feed-ramp): your component library handed to coding agents before they write markup, not just drift caught after. Published on [RubyGems.org as `ui_guardrails`](https://rubygems.org/gems/ui_guardrails). The Ruby module stays `Guardrails` (so `require "guardrails"` is unchanged) — only the gem package name on rubygems carries the `ui_` prefix, to clear RubyGems' similarity rule against the unrelated [`guard-rails`](https://rubygems.org/gems/guard-rails) gem. See [`doc/ROADMAP.md`](doc/ROADMAP.md) for status, [`CHANGELOG.md`](CHANGELOG.md) for the full naming rationale.

---

## The problem

AI-assisted Rails development is fast. Too fast. Without design guardrails in place, codebases accumulate:

- Inline `style=` attributes nobody asked for
- Hex literals scattered across views that should reference a token
- `bg-[#fa3]` arbitrary Tailwind values when a theme color already exists
- Six near-duplicate "card" partials when one parameterized component would do
- `<button>` elements with no accessible name
- Orphan ViewComponent slots and Stimulus controllers
- The same 7-class utility soup pasted onto 30 buttons

Guardrails catches these patterns without rendering anything — every detector is a static AST walk over your source. Findings stream into a unified report (text or JSON) with the same exit-code contract every other lint tool uses.

---

## Installation

Guardrails works two ways: **installed in your project** (auto-loaded via a Railtie, runs the audit on every CI pass) or **sidecar** (cloned alongside your app, audits any tree on demand without modifying its Gemfile).

### Installed in-project (recommended)

```ruby
# Gemfile
group :development, :test do
  gem "ui_guardrails", "~> 2.0"
end
```

```bash
bundle install
bundle exec rake ui_guardrails:init       # writes guardrails.yml, scaffolds MQs
bundle exec rake ui_guardrails:audit      # run the full audit
```

The gem's Railtie auto-loads rake tasks and (when [Lookbook](https://lookbook.build) is also in your Gemfile) registers the **Guardrails** panel inside every preview's inspector.

### Sidecar (no Gemfile change)

Useful when you want to audit a Rails app without committing to the gem yet, or in CI for repos you don't own.

```bash
git clone https://github.com/meticulous/guardrails ~/code/guardrails
cd ~/code/guardrails && bundle install

# From your Rails app's root:
cd ~/code/my-rails-app
bundle exec --gemfile=~/code/guardrails/Gemfile \
  rake -f ~/code/guardrails/lib/tasks/ui_guardrails.rake \
  ui_guardrails:audit
```

Every rake task accepts the same env vars in sidecar mode as in-project. The tasks default `root` to `Rails.root` when Rails is loaded, else `Dir.pwd` — so just run from the target app's root.

---

## Quick start

### Feed Ramp in 60 seconds

Give your coding agents the components you already have:

```bash
bundle add ui_guardrails --group "development, test"

# 1. Component manifest + agent rules: writes .ui_guardrails/manifest.json and
#    COMPONENTS.md, and a managed block in CLAUDE.md and AGENTS.md plus a Cursor rule
bundle exec rake ui_guardrails:feed_ramp:rules

# 2. Optional: the MCP server (search_components, get_component, check_snippet)
bundle exec rake ui_guardrails:feed_ramp:mcp:install        # AGENT=all adds Codex, Cursor and Gemini CLI

# 3. Optional: the Modern Web Guidance skill (Google Chrome and contributors), so
#    agents also look up current HTML, CSS and JS practice. Run step 1 again after it
bundle exec rake ui_guardrails:feed_ramp:modern_web:install

# 4. Commit it, so every clone and every agent session has it
#    (and .mcp.json if you ran step 2, the skill's files if you ran step 3)
git add .ui_guardrails CLAUDE.md AGENTS.md .cursor/rules

# 5. In CI: fail when the manifest or rules are out of date, and on drift,
#    including hand-written markup that copies a component (component_match)
CHECK=1 bundle exec rake ui_guardrails:feed_ramp:rules
bundle exec rake ui_guardrails:audit

# 6. Measure it: score now, again after an agent session, and compare
bundle exec rake ui_guardrails:feed_ramp:score
bundle exec rake ui_guardrails:feed_ramp:score BASELINE=last
```

Nothing boots your app, and ViewComponent, Phlex and Lookbook are all optional. `component_match` is a warning, so it fails the audit; set `feed_ramp.component_match: suggestion` in `guardrails.yml` to see what it catches before it gates builds. Details are in [Feed Ramp](#feed-ramp).

### The audit

```bash
# One-time setup — detects your token stack, writes guardrails.yml,
# scaffolds prefers-color-scheme media queries if your stylesheet
# doesn't already have them. Interactive when on a TTY; CI-safe
# default fallback otherwise.
bundle exec rake ui_guardrails:init

# Full audit — exits 1 on any violation.
bundle exec rake ui_guardrails:audit

# Get a markdown checklist of fixable findings:
SUGGEST=1 bundle exec rake ui_guardrails:audit
# → writes doc/guardrails-suggestions-{TIMESTAMP}.md

# Auto-fix raw_color and tailwind_arbitrary where a token matches:
APPLY=1 bundle exec rake ui_guardrails:audit
```

---

## Tasks at a glance

| Task | What it does |
|---|---|
| `ui_guardrails:init` | Stack detection, writes `guardrails.yml`, scaffolds prefers-color-scheme / prefers-contrast media queries. Refuses to overwrite an existing config — `FORCE=1` overrides. |
| `ui_guardrails:audit` | Runs every detector — view drift, stimulus, partial similarity, view-components, a11y, cross-codebase patterns, class-itis. Exits 1 on violations. |
| `ui_guardrails:tui` | The same audit, browsable: a severity roll-up you drill into (category → finding → source), regroup by file, filter, and jump from into your editor or the HTML report. See [Browsing findings](#browsing-findings). |
| `ui_guardrails:icons` | Generates an SVG sprite from `app/assets/images/icons/`, flags inline `<svg>` in views, catches emoji / glyph icons across views + helpers + models + JS + locales, reports unused sprite entries. **Exits 1** on any inline SVG, unknown sprite reference, or emoji/glyph icon (1.5.0). Dead icons stay reporting-only. `SUGGEST=1` prints sprite-name suggestions; `FORMAT=json` emits the machine-readable payload. |
| `ui_guardrails:tokens` | Parses your color and type-scale tokens (CSS vars / SCSS vars / Tailwind v3 config / Tailwind v4 `@theme`), reports hex literals in stylesheets that should reference a token. |
| `ui_guardrails:a11y:deep` | Reads axe-core JSON output and folds it into the unified report. Doesn't run axe itself (no Capybara / headless Chrome runtime deps) — point it at axe output your existing tooling produces. |
| `ui_guardrails:visual:deep` | Consumes screenshot-diff tool output (snap_diff-capybara today; BackstopJS in flight, [#15](https://github.com/meticulous/guardrails/issues/15)) and reports visual regressions. Same parse-only design — your existing test toolchain runs screenshots; Guardrails reports. |
| `ui_guardrails:hooks:install` | Adds Guardrails to coding agents' hooks (Claude Code, Codex, Cursor, Gemini CLI), so drift an agent introduces goes back to it while it works. See [Coding agent hooks](#coding-agent-hooks). |
| `ui_guardrails:feed_ramp:manifest` | Writes `.ui_guardrails/manifest.json` and `COMPONENTS.md`: the app's components and tokens, for coding agents. `CHECK=1` exits 1 when they're out of date. See [Feed Ramp](#feed-ramp). |
| `ui_guardrails:feed_ramp:score` | Scores UI drift per 100 templates (hardcoded values, reinvented components, a11y) and saves it under `.ui_guardrails/scores/`. `BASELINE=last` or a path compares two runs; `FORMAT=json`. Never fails. See [Drift score](#drift-score). |
| `ui_guardrails:feed_ramp:mcp:install` | Adds the Feed Ramp MCP server to `.mcp.json` (Claude Code); `AGENT=codex,cursor,gemini` or `all` for the others. See [MCP server](#mcp-server). |
| `ui_guardrails:feed_ramp:modern_web:install` | Installs the [Modern Web Guidance](https://developer.chrome.com/docs/modern-web-guidance) skill with its own installer (needs Node.js 22+). The agent rules mention it once it's in the project. See [Modern Web Guidance](#modern-web-guidance). |
| `ui_guardrails:feed_ramp:rules` | Writes the manifest, then a block pointing coding agents at it in `CLAUDE.md` and `AGENTS.md`, plus `.cursor/rules/ui-guardrails.mdc`. `TARGETS=` picks files, `CHECK=1` exits 1 when anything is out of date, `REMOVE=1` takes the blocks out. See [Feed Ramp](#feed-ramp). |

Before 2.0 the tasks were `guardrails:*`. Those names still run the `ui_guardrails:` task, with a deprecation notice, until 3.0.

---

## Detectors

### View-level drift (`ui_guardrails:audit`)

Static AST walk over every `.html.erb` under `app/views/` and `app/components/` (via [Herb](https://github.com/marcoroth/herb), the ERB-aware parser):

| Detector | Catches |
|---|---|
| `inline_style` | `<div style="…">` — inline styles bypass tokens entirely. |
| `raw_color` | Hex / rgb literals in color-bearing attributes (`fill`, `stroke`, `color`, `bgcolor`, `background`, `data-*color*`, etc.). |
| `tailwind_arbitrary` | `bg-[#fa3]`, `text-[14px]`, `p-[7px]` — arbitrary values that bypass the theme. |
| `helper_recommended` | `<button>` / `<a>` wrapping `<%= … %>` ERB output. Suggests `tag.button` / `link_to` / `button_to` for clean accessible names. Skips elements that already have `aria-label`. |
| `component_match` | Hand-written markup copying one of your components: its signature class (`class="button …"` for ButtonComponent) on any tag, or its root tag with most of its classes. Suggests the component's real usage example. Needs a [Feed Ramp](#component-match) manifest; warning by default. |
| `image_alt` / `button_name` / `link_name` / `input_label` | The four most common static a11y misses (see [`doc/A11Y.md`](doc/A11Y.md)). |

### Suggest mode and auto-fix

- `SUGGEST=1 rake ui_guardrails:audit` writes `doc/guardrails-suggestions-{TIMESTAMP}.md` — a markdown checklist with one `[ ]` per fixable finding, the rule that fired, and the proposed replacement (closest token by exact match, else near-match within a configurable channel-distance).
- `APPLY=1 rake ui_guardrails:audit` auto-fixes `raw_color` (→ `var(--token)`) and `tailwind_arbitrary` (→ Tailwind theme color shorthand) when a matching token exists. Near-match auto-fix is gated by `near_match_policy` in `guardrails.yml` (`fix` / `leave` / `notify`).

### Tokens

`Guardrails::Tokens` parses every token source it can find:

- CSS custom properties in your configured `colors_file`
- SCSS variables in the same
- Tailwind v3 `tailwind.config.js` — flat colors and nested scales (`gray.50` → `gray-50`). Found automatically at the repo root or at `config/tailwind.config.js` (the `tailwindcss-rails` default); set `tokens.tailwind_config` for anything else (`.cjs`, `.ts`, monorepo paths)
- Tailwind v4 `@theme {}` blocks — picked up by the CSS-custom-property scanner

Then scans every other stylesheet for hex literals and reports drift, matching each to the closest defined token. Block + line comments are stripped before matching, preserving line/column positions so reports are accurate.

### Stimulus

`Guardrails::StimulusAudit` cross-references `data-controller="…"` attributes against `app/javascript/**/controllers/*_controller.{js,ts}` (works across importmap, Webpacker, Vite, and Avo's `app/javascript/js/controllers/` layout):

- **Orphaned** — controller referenced in a view but no JS file defines it.
- **Dead** — JS file exists but no view references it.
- Picks up Ruby helper syntax: `tag.div(data: { controller: "foo" })`.

### ViewComponent

`Guardrails::ViewComponentAudit`:

- Reports components without a preview file (Lookbook discoverability).
- Reports `renders_one` / `renders_many` slots declared in the component class but never referenced in the template (orphan slots).

### Partial similarity

`Guardrails::PartialSimilarity` runs n-gram Jaccard over the tag-stream of every partial and component template, groups near-duplicates by connected components, and reports clusters above the configured threshold (default 0.7). Pair sample lines surface the most similar match in each cluster.

### Cross-codebase patterns (0.3.0)

`Guardrails::CrossCodebasePatterns` walks every element subtree, fingerprints the tag-only shape (`article(header(h2),section(p,p),footer(a))`), and reports shapes appearing 3+ times with ≥ 5 elements. Distinct from PartialSimilarity (which compares **existing** partials) — this finds shapes that **should** be partials but aren't yet. Dedupes redundant nested patterns so a repeating table doesn't generate three findings (`table(…)`, `thead(…)`, `tr(…)`) for the same locations.

### Class-itis (0.4.0)

`Guardrails::ClassItis` groups elements by `(tag, sorted-uniq-class-list)`. Reports tuples with ≥ 5 distinct classes appearing on the same tag in ≥ 3 places — the classic AI-assisted-Rails failure mode of 8-utility soup pasted across many buttons when the codebase should have a shared component or `@apply` rule. ERB-driven class fragments are dropped; only the static portion is fingerprinted.

### Visual diff via snap_diff-capybara (0.8.0)

`Guardrails::VisualDiff` consumes screenshot-diff tool output and folds findings into the unified report. The shipped adapter is [`snap_diff-capybara`](https://github.com/snap-diff/snap_diff-capybara) — the Rails-native baselines-in-git visual-regression gem:

```bash
# Your existing system tests produce diffs under doc/screenshots/
bundle exec rspec spec/system/

# Fold visual-diff findings into the audit:
VISUAL_DIFF=1 bundle exec rake ui_guardrails:audit
```

Or standalone via `rake ui_guardrails:visual:deep`. Parse-only — same trade as deep a11y, no Capybara/Chromium runtime deps in the gem. BackstopJS adapter tracked in [#15](https://github.com/meticulous/guardrails/issues/15). See [`doc/VISUAL-DIFF.md`](doc/VISUAL-DIFF.md).

### Deep a11y via axe-core JSON (0.6.0)

`Guardrails::A11yDeep` consumes axe-core JSON output and folds findings into the unified report:

```bash
npx @axe-core/cli http://localhost:3000/ --save axe.json
AXE_JSON=axe.json bundle exec rake ui_guardrails:audit
```

Or standalone via `rake ui_guardrails:a11y:deep`. Stays parse-only — your existing test toolchain runs axe (axe-core-rspec, the CLI, Puppeteer, a CDP script — anything that emits axe v4 JSON), Guardrails provides the merge + report. See [`doc/A11Y.md`](doc/A11Y.md).

### Lookbook auto-panel (0.5.0)

When [Lookbook](https://lookbook.build) is in the Gemfile, Guardrails auto-registers a `:guardrails` panel that appears next to every preview's Source / Notes panels. The panel renders `Guardrails::Lookbook::ComponentReport#for(component_class_name)` — drift in the template, orphan slots, similar templates — inline. Host apps override by dropping their own partial at `app/views/lookbook_panels/_guardrails.html.erb`. See [`doc/LOOKBOOK.md`](doc/LOOKBOOK.md).

### Emoji and glyph icons (1.5.0)

The `ui_guardrails:icons` task now catches emoji and Unicode-dingbat glyphs used as UI iconography — the most common way AI-assisted code bypasses the sprite. Two tiers, both on by default:

| Tier | What matches | Example |
|---|---|---|
| `emoji` | Extended_Pictographic pictographs + multi-codepoint sequences (VS16, ZWJ, flags, keycaps) | `📄` `👨‍👩‍👧` `🇺🇸` `1️⃣` |
| `glyph` | Single codepoints in Arrows, Misc Technical, Geometric Shapes, Misc Symbols, Dingbats, Misc Symbols & Arrows | `✓` `→` `★` `●` `⚠` |

Grapheme-cluster iteration counts VS16-styled pictographs / ZWJ families / flag pairs / keycaps as **one** violation with the full cluster in the snippet. `\p{Emoji}` is deliberately **not** used (it matches ASCII digits, `#`, and `*`). Explicitly excluded from both tiers: letters, digits, punctuation, currency signs, `©®™`, ellipsis, dashes, quotes — those are copy, not icons.

**Scans**, by default: `app/views`, `app/components`, `app/helpers`, `app/models`, `app/presenters`, `app/javascript`, and `config/locales` — where the emoji-as-icon pattern usually lives (a helper returning `"📄"` per content type, a Stimulus controller setting `textContent = "✓"`). Comments are masked per file type: Prism-parsed for `.rb`, `<%# %>` for ERB, `//` and `/* */` for JS/SCSS/CSS, `#` for YAML. Line and column stay accurate.

**Config** in `guardrails.yml` (defaults shown; `ui_guardrails:init` writes this block for you):

```yaml
guardrails:
  icons:
    emoji:
      enabled: true          # the emoji tier
      glyphs: true           # the dingbat/glyph tier; false = emoji only
      scan_paths:            # optional override of the default file list
      allow_files:           # emoji-as-content: scanned but never flagged
        - app/models/reaction.rb
      allow_chars: []        # specific codepoints to never flag, e.g. ["→"]
```

**Inline escape** for a single line — the first inline-marker convention in the gem:

```ruby
BAD = "📄" # guardrails-ok: emoji intentional in this seed data

# guardrails-ok: emoji shipping consciously — deprecation notice text
LEGACY = "📎 old attachment"
```

Works on the same line or the preceding line, in Ruby `#` comments, ERB `<%# %>` blocks, JS `//`, SCSS `//`, and YAML `#`.

**Suggestions** with `SUGGEST=1`: when the consumer's sprite contains a conventional name for the flagged emoji (`📄 → check for icon-file or icon-document`, `✓ → icon-check` / `icon-checkmark`), the task prints `→ use <use href="#icon-document"/>`. When no equivalent exists, it prints `→ no sprite equivalent — add one`. Only names the consumer's `collect_icon_names` includes are surfaced. No auto-fix path (`APPLY=1`) — the right sprite name depends on the consumer's semantics.

**No-fix policy**: emoji contribute to `ui_guardrails:icons` exit code (part of Result#violations?). Dead icons stay reporting-only — deleting a file is a human decision.

### Detectors from other gems

Other gems add detectors to `ui_guardrails:audit` with `Guardrails::Report::Detectors.register(name, klass)`. They run after the built-ins and show up in the text report, the summary, `FORMAT=json` (under `extensions.<name>`), `FORMAT=html` and the TUI. The class answers:

| Method | Does |
| --- | --- |
| `.enabled?(env:)` | Whether this audit runs it, from the audit's env vars or the gem's own config |
| `.max_severity` | The most serious severity it reports; `SEVERITY=` above that skips it without running it |
| `.new(root:, output:, style:)` | Built like the built-in detectors |
| `#run` | Returns its result and prints its own section to `output` |
| `#categories(result)` | `Report::Category`s for the TUI, HTML and JSON findings |
| `#summary_entry(result)` | A `Report::Summary::Entry` for the rollup |
| `#to_h(result)` | Its `FORMAT=json` fragment |
| `#failing?(result)` | Its own exit-code rule |

Registration checks the class has all of these. Detectors only read what's already on disk; they never capture or call an API, because the TUI re-runs every detector on each `r`. ui_guardrails-browser registers its heuristic review this way.

---

## Output

Every task prints a human-readable text report by default and exits 1 when violations or failing findings exist. For machine consumption:

```bash
FORMAT=json bundle exec rake ui_guardrails:audit > findings.json
```

The JSON payload has a `summary:` block with finding counts per category plus per-detector arrays — see `Guardrails::Report::Run#to_h` for the exact shape.

### Browsing findings

On a real codebase the text report is long (one of our test apps produces 981 findings). Two ways to navigate it instead of scrolling it:

```bash
bundle exec rake ui_guardrails:tui                 # interactive, in the terminal
FORMAT=html bundle exec rake ui_guardrails:audit   # one self-contained HTML file
```

**`ui_guardrails:tui`** opens on the same severity roll-up the text report leads with. `⏎` drills in — category → findings → a single finding with its suggestion, every location, and the source around it. `tab` regroups the whole thing by file (the files with the most findings first), `/` filters across category, title, suggestion, and path, `o` opens the highlighted location in your editor at the right line, `w` writes and opens the HTML report, `r` re-runs the audit, `?` lists the rest. It takes the same env vars as `ui_guardrails:audit` except `APPLY` and `SUGGEST` — browsing never rewrites files. No new dependencies: it's built on Ruby's bundled `io/console`.

The editor is `$GUARDRAILS_EDITOR`, then `$VISUAL`, then `$EDITOR`. VS Code-family, Zed, Sublime, TextMate, JetBrains, Helix, and vim/nvim/nano/emacs all open at the finding's line; anything else gets the file path. With no editor set, it falls back to `open` / `xdg-open`.

**`FORMAT=html`** writes `tmp/guardrails/audit.html` (override with `OUTPUT=path`): the roll-up, every finding with its suggestion, locations, and snippet, a live filter, and severity toggles. Everything is inline — no server, no assets, no network — so it works opened from disk or uploaded as a CI artifact. File locations become editor links once you pick your editor from the menu in the header (remembered per browser). Note the file embeds absolute paths from the machine that generated it; that's what makes the editor links work.

### Common env vars

| Var | Effect |
|---|---|
| `SUGGEST=1` | Write the markdown checklist alongside the text report. |
| `APPLY=1` | Auto-fix raw_color + tailwind_arbitrary where tokens match. |
| `SEVERITY=error` / `SEVERITY=warning` | Severity floor. `error` checks errors only; `warning` drops suggestions; default is everything. Applies to the report, the exit code, JSON, HTML, and the TUI alike. Detectors that can only produce muted findings aren't run. An unrecognized value aborts rather than being ignored. |
| `FORMAT=json` | Emit one JSON document to stdout (all other audit output is suppressed). |
| `FORMAT=html` / `OUTPUT=path` | Write the self-contained HTML report (default `tmp/guardrails/audit.html`). |
| `GUARDRAILS_EDITOR=cmd` | Editor `ui_guardrails:tui` opens locations in. Falls back to `$VISUAL`, then `$EDITOR`. |
| `FORCE=1` | Bypass `init`'s refuse-to-overwrite default. |
| `AXE_JSON=path` | Fold axe-core findings into the unified report. |
| `VISUAL_DIFF=1` | Fold visual-diff findings into `ui_guardrails:audit`. Embedded installs can flip this on permanently via `Guardrails.configure { \|c\| c.visual_diff.enabled = true }`. |
| `VISUAL_DIFF_DIR=path` / `VISUAL_DIFF_THRESHOLD=0.02` | Tune the visual-diff snap_diff adapter and mismatch threshold. |
| `SIMILARITY_THRESHOLD=0.85` | Override the partial-similarity Jaccard threshold. |
| `PATTERN_MIN_SIZE=8` / `PATTERN_MIN_OCCURRENCES=4` | Tune the cross-codebase pattern detector. |
| `CLASSITIS_MIN_CLASSES=6` / `CLASSITIS_MIN_OCCURRENCES=4` | Tune the class-itis detector. |

---

## Feed Ramp

The audit catches drift after it's written. Feed Ramp gives coding agents the app's real component library first, so they render the components you have instead of reinventing them.

```bash
bundle exec rake ui_guardrails:feed_ramp:rules           # manifest + agent rules (CLAUDE.md, AGENTS.md, Cursor)
CHECK=1 bundle exec rake ui_guardrails:feed_ramp:rules   # in CI: exit 1 if any of them is out of date
bundle exec rake ui_guardrails:feed_ramp:manifest        # just .ui_guardrails/manifest.json + COMPONENTS.md
```

The manifest lists every ViewComponent and Phlex component: class, file, template, constructor params with their defaults, slots, the variants and states from its Lookbook / ViewComponent previews, its doc comment, and one usage example. It also lists the design tokens: everything `ui_guardrails:tokens` reads, plus custom properties in the `:root { }` and Tailwind v4 `@theme { }` blocks of your stylesheets.

- **No app boot, network or model call.** Everything is read by parsing the source with Prism. Neither ViewComponent, Phlex nor Lookbook has to be installed: a class is a component when its superclass chain (through your own `ApplicationComponent` or `Components::Base`) reaches `ViewComponent::Base` or `Phlex::HTML`.
- **Examples are copied, never written.** Each component's example is the shortest render of it (`render X.new(…)`, or a Phlex kit call like `Alert(…)`) in a visible preview, or else in a template or Ruby view, copied verbatim. A usage that names the component in full wins, since it works in any view. A component nothing renders gets no example.
- **Deterministic.** Same source, byte-identical files: no timestamps, everything sorted. Commit both files so agents on a fresh clone have them and component API changes show up in review. `CHECK=1` rebuilds and compares, so it fails only when the committed files are actually wrong, not on every view edit.
- **Phlex slots are a heuristic.** Phlex has no slot declarations, so public methods taking a block are listed instead and marked `heuristic`.

### Agent rules

`ui_guardrails:feed_ramp:rules` writes the manifest, then tells agents it exists, in the files they read at the start of every session:

| Target | File | |
| --- | --- | --- |
| `claude` | `CLAUDE.md` | default |
| `agents` | `AGENTS.md` (Codex, Cursor, and others) | default |
| `cursor` | `.cursor/rules/ui-guardrails.mdc` | default; attached when the agent works in `app/views` or a component path |
| `gemini` | `GEMINI.md` | opt in |
| `copilot` | `.github/copilot-instructions.md` | opt in |

Pick them with `TARGETS=claude,agents,copilot` or `rules_targets:` in `guardrails.yml`. The block names the components (up to 50) and token categories, and says to render an existing component before writing markup by hand.

- **Everything outside the markers is kept.** The block sits between `<!-- ui_guardrails:feed_ramp:begin -->` and `<!-- ui_guardrails:feed_ramp:end -->`; only that part is ever rewritten. A file without the markers gets the block at the end, and a second run with the same manifest changes nothing. Move the block anywhere in the file and it stays there.
- **Broken markers stop the run.** With an unpaired, duplicated or reversed marker, nothing is written and the error names the file.
- **One copy per file.** When `CLAUDE.md` imports `@AGENTS.md`, or is a link to it, the block only goes in `AGENTS.md`.
- **`REMOVE=1`** takes the blocks out and deletes the files that held nothing else.

The Cursor rule file is Feed Ramp's own and is rewritten whole. If a file at that path wasn't written by Feed Ramp, it's left alone and the run fails.

When [agent hooks](#coding-agent-hooks) are installed, each new session also gets a one-line pointer to `COMPONENTS.md`.

### MCP server

`ui_guardrails-mcp` serves the manifest to coding agents as [MCP](https://modelcontextprotocol.io) tools over stdio:

| Tool | Gives |
| --- | --- |
| `list_components` | every component in brief (kind, one-line description, params, slots), and the token names by category |
| `get_component(name)` | one component's full entry: params with defaults, slots, previews, usage example. `Badge` finds `Admin::BadgeComponent` |
| `search_components(query)` | components ranked by name, description, params, slots and preview labels |
| `check_snippet(source, language?, path?)` | for ERB: the audit's and static a11y's findings, `component_match` included. For ERB and Ruby (Phlex): every `SomeComponent.new(...)` and Phlex kit call (`Alert(...)`) checked against the manifest (unknown component, keyword it doesn't take, required one missing, wrong positional count, and a likely typo a `**options` param would swallow) |

```bash
bundle exec rake ui_guardrails:feed_ramp:mcp:install              # .mcp.json (Claude Code)
AGENT=all bundle exec rake ui_guardrails:feed_ramp:mcp:install    # + .codex/config.toml, .cursor/mcp.json, .gemini/settings.json
```

The install keeps every other server and setting in those files and is safe to run again. It uses `bundle exec` when your Gemfile has the gem, and the bare executable otherwise. Cursor's entry passes `--root ${workspaceFolder}`, since Cursor doesn't promise to start servers in the project. Claude Code asks you to approve a project server the first time, and Codex reads `.codex/config.toml` only in projects you've trusted. In that file the install owns the `[mcp_servers.ui_guardrails]` table and leaves every other line as it was.

The server never boots the app. It builds the manifest from source when it starts and rebuilds it whenever a component, preview, view, stylesheet or `guardrails.yml` is added, removed or changed. If that changes the committed files it rewrites `.ui_guardrails/`, so `component_match` sees the same components. Pass `--no-write` (or `WRITE=0` for `rake ui_guardrails:feed_ramp:mcp`) to leave them alone. Once a project config starts the server, `ui_guardrails:feed_ramp:rules` mentions the tools in the agent rules block.

### Modern Web Guidance

Feed Ramp tells agents what your app already has. [Modern Web Guidance](https://developer.chrome.com/docs/modern-web-guidance) tells them what the web platform already has: a skill that has an agent look up current practice for dialogs, popovers, forms, layout, animation, performance and accessibility before it writes HTML, CSS or client-side JavaScript, instead of the older patterns in its training data.

```bash
bundle exec rake ui_guardrails:feed_ramp:modern_web:install   # runs `npx -y modern-web-guidance@latest install`
bundle exec rake ui_guardrails:feed_ramp:rules                # the rules now mention the skill
```

- **Their installer, not a copy.** The task runs Modern Web Guidance's own interactive install in your project and nothing of it ships in this gem, so the guides are always theirs and current. It needs Node.js 22 or later. `ARGS="…"` is passed through to the installer.
- **Your library comes first.** Once the skill is in a project skills directory (`.claude/skills`, `.agents/skills` and the like), the agent rules block tells agents to search it for platform HTML, CSS and JavaScript, and to use it where no component of yours does the job and inside the components themselves.
- **Commit the skill** with the rules (`.agents/skills/modern-web-guidance`, the links to it such as `.claude/skills/modern-web-guidance`, and `skills-lock.json`), or `CHECK=1` in CI sees rules that mention a skill the checkout doesn't have. If your team installs it per user or as an agent plugin instead, set `feed_ramp.modern_web_guidance: true` in `guardrails.yml`; `false` keeps it out of the rules.
- **Telemetry is theirs.** The Modern Web Guidance CLI sends Google anonymous usage data: installs, the calling agent, guide IDs and the agent's search queries. The task says so before it runs. `DISABLE_TELEMETRY=1` in your shell profile opts out.

Modern Web Guidance is by Google Chrome and its contributors, stewarded with the Microsoft Edge, Mozilla Firefox and MDN teams. Its code is Apache-2.0 and its guides are CC BY 4.0. Source: [GoogleChrome/modern-web-guidance](https://github.com/GoogleChrome/modern-web-guidance).

### Component match

Once a manifest exists, `ui_guardrails:audit` (and so the agent hooks and the Lookbook panel) flags markup that copies one of your components instead of rendering it:

```
! WARNING — component_match (1 finding)
  [warning]  component_match: <button type="button" class="button button--primary"> looks like ButtonComponent
    → render ButtonComponent instead, e.g. render(ButtonComponent.new(label: "Save"))
    app/views/welcome/broken.html.erb:42:1
```

Each component's root element is read when the manifest is built: the first element of its ERB template (or the first `<%= tag.div … %>` it opens with), or the first tag its Phlex `view_template` or ViewComponent `call` builds, following the component's own methods. Its classes are the ones it always has, read without rendering: literal strings, and the unconditional string arguments of a class helper (`class_names("kbd", "kbd--bare": @bare)` and `build_css("button", …)` give `kbd` and `button`), followed through methods such as `class: css_classes`, `**wrapper_attributes` or `attrs[:class] = …`. Conditional and interpolated classes (`btn--<%= @variant %>`, `alert--#{@tone}`) don't count. Markup matches with either:

- **the component's signature class, on any tag:** a root class named after the component (`button` or `button-component` for ButtonComponent, `icon-button` for IconButtonComponent), even on its own. Any tag, because a button component may render a link; or
- **the same tag and most of a long class list:** at least `coverage` (0.8) of the root's classes, when the root has at least `min_classes` (3). Shorter lists of generic utilities never match.

A component whose classes all depend on its arguments (a `class:` it's given, or one picked in an `if`) has nothing to match on.

A component's own template is never matched against itself. The rule reads the committed manifest rather than parsing the app, so it adds nothing noticeable to a hook call, and it says nothing until `ui_guardrails:feed_ramp:manifest` has run.

It's a **warning**, so it fails `ui_guardrails:audit` like any other warning. To try it out first, lower it to a suggestion, which reports without failing:

```yaml
guardrails:
  feed_ramp:
    component_match: suggestion     # or warning (default), error, off
    # or, to tune matching too:
    # component_match:
    #   severity: suggestion
    #   min_classes: 3
    #   coverage: 0.8
```

### Drift score

```bash
bundle exec rake ui_guardrails:feed_ramp:score                  # before
# ...an agent session, a branch, turning Feed Ramp on...
bundle exec rake ui_guardrails:feed_ramp:score BASELINE=last    # after, compared with the last saved run
```

```
UI drift score: 116.7 issues per 100 templates (7 issues in 6 templates)

  Hardcoded values            1  stylesheet_color 1
  Reinvented components       4  class_itis 4
  Accessibility               2  image_alt 1, link_name 1

Against 2026-10-19T12:00:00Z, 3f2c1aa: 8 → 7 issues (−1), 133.3 → 116.7 per 100 templates
  Hardcoded values            3 → 1 (−2)
  Reinvented components       4 → 4 (0)
  Accessibility               1 → 2 (+1)
  Most changed: app/views/pages/home.html.erb −3, app/views/pages/about.html.erb +2
```

| Bucket | Counts |
| --- | --- |
| Hardcoded values | raw colours, arbitrary Tailwind values and inline styles in templates; hex literals in stylesheets outside the token files |
| Reinvented components | markup copying a component (`component_match`), each occurrence of a class-itis cluster or repeated markup, and each pair of near-identical partials |
| Accessibility | static a11y findings (missing alt text, unnamed buttons and links, unlabelled inputs) |

The headline is issues per 100 templates, so apps and branches of different sizes compare. Templates are the ones `ui_guardrails:audit` scans: its `scan_paths` and `ignore` apply to every bucket.

Each run is saved as JSON under `.ui_guardrails/scores/` (which keeps itself out of git) with the totals, per-type and per-file counts, the git commit, the gem version and a digest of `guardrails.yml`. `BASELINE=` takes `last` or a path to any saved score, and the comparison says when the config or gem version differ between the two. To keep runs comparable it uses the detectors' default thresholds and ignores the audit's env vars. It always exits 0; gate CI with `ui_guardrails:audit`.

Config in `guardrails.yml` (all optional; defaults shown):

```yaml
guardrails:
  feed_ramp:
    component_paths: [app/components, app/views/components]
    preview_paths: [test/components/previews, spec/components/previews, lookbook/previews]
    token_files: []          # extra files whose custom properties are all tokens
    output_dir: .ui_guardrails
    rules_targets: [claude, agents, cursor]   # also: gemini, copilot
```

Preview directories your Rails config adds are found too, without booting the app: `config.view_component.previews.paths << Rails.root.join("…").to_s` (or `preview_paths`, `+=`, `concat`) and `config.lookbook.preview_paths` in `config/application.rb` or `config/environments/{development,test}.rb`, written as strings or built from `Rails.root` or `__dir__`. List any computed at boot here.

---

## Coding agent hooks

```bash
bundle exec rake ui_guardrails:hooks:install                  # Claude Code
AGENT=claude,codex bundle exec rake ui_guardrails:hooks:install
AGENT=all bundle exec rake ui_guardrails:hooks:install        # Claude Code, Codex, Cursor, Gemini CLI
```

This adds Guardrails to each agent's project hook config. It keeps whatever else is in that file and is safe to run again. Each hook calls `guardrails-hook <agent> <event>`, which runs only the parse-only checks: view drift (raw colours, Tailwind arbitrary values, inline styles, helper recommendations) and static a11y. A typical call takes a fraction of a second.

It reports only what the agent introduced. A template is compared with its version at `HEAD`, so drift that was already there isn't the agent's to fix. Findings are matched by content, so a finding on a line that moved isn't counted as new.

| When | What happens |
| --- | --- |
| After the agent edits a template | The drift it just introduced goes back to it as context. Nothing is blocked. |
| When it tries to finish | New **errors** in any template changed since `HEAD` send it back to work, once per turn. Warnings alone don't. |
| When a session starts | Where the [Feed Ramp](#feed-ramp) component list is, when the app has one, and notes from other gems (ui_guardrails-browser adds open visual-review rejections). |

| Agent | Config | Notes |
| --- | --- | --- |
| Claude Code | `.claude/settings.json` | `PostToolUse`, `Stop`, `SessionStart` |
| Codex | `.codex/hooks.json` | Same events. Edits arrive as patches, so file names come from the patch. Trust the hooks in `/hooks` once. |
| Cursor | `.cursor/hooks.json` | `stop` and `sessionStart` only: Cursor's after-edit output doesn't reliably reach the model, so the stop check covers every changed template. Cursor also runs `.claude/settings.json` hooks; the hook recognises Cursor's input and doesn't run twice. |
| Gemini CLI | `.gemini/settings.json` | `AfterTool` (`write_file`, `replace`), `AfterAgent`, `SessionStart` |

The hook never breaks the agent's turn: if anything goes wrong it prints `{}`, explains on stderr, and exits 0. The installed command ends in `|| echo '{}'`, so the same holds when the hook can't start at all. That happens on a branch whose Gemfile doesn't have the gem, since the agent's config usually isn't tracked by git and outlives the branch. Running the install again replaces an earlier install's hooks instead of adding new ones beside them. Other gems add to the same events with `Guardrails::Hooks.register(name, contributor)`, shipped at `lib/guardrails/hook_contributors/<name>.rb` so the hook finds them without booting the app.

---

## CI

The audit task is a single shell command:

```yaml
# .github/workflows/ci.yml
- name: Guardrails audit
  run: bundle exec rake ui_guardrails:audit
```

Adopting Guardrails on an existing codebase usually means a backlog of warnings you can't clear in one PR. Gate on errors now and ratchet down later:

```yaml
- name: Guardrails audit (errors only)
  run: bundle exec rake ui_guardrails:audit SEVERITY=error
```

`SEVERITY=error` exits 1 only when there are error-level findings (raw colors, arbitrary Tailwind values, a11y, visual diffs) and skips the warning- and suggestion-tier detectors entirely, so it's also the fastest way to run the audit. The report ends with a line saying what wasn't checked, so a green run can't be mistaken for a clean codebase.

For richer integration:

```yaml
- name: Guardrails audit (JSON)
  run: bundle exec rake ui_guardrails:audit FORMAT=json > findings.json
  continue-on-error: true

- name: Upload findings
  uses: actions/upload-artifact@v4
  with:
    name: guardrails-findings
    path: findings.json
```

---

## Configuration

`guardrails.yml` at the repo root. `ui_guardrails:init` writes a sensible default after detecting your stack — what's below is annotated to show every available key:

```yaml
guardrails:
  scan_paths:
    - app/views
    - app/components
  ignore:
    - app/views/layouts
  tokens:
    # Where your color tokens live. The init task picks this up from
    # stack detection (CSS vars, SCSS, Tailwind v3/v4); edit if it
    # guessed wrong.
    colors_file: app/assets/stylesheets/tokens/_colors.css
    type_scale_file: app/assets/stylesheets/tokens/_type.css
    # Optional. Tailwind v3 config to read theme colors from. Not needed
    # for tailwind.config.js at the root or under config/ — init writes
    # it for the latter, and both are discovered without it.
    tailwind_config: config/tailwind.config.js
    # Per-channel R/G/B distance at which a near-match becomes a
    # "close enough to suggest" finding. 0 = exact only; 4 = default
    # (catches #0066ff ↔ #0067fe); 20+ = aggressive.
    near_match_threshold: 4
    # What to do with near-matches: notify (default; suggest in the
    # report), fix (auto-fix with APPLY=1), or leave (silence).
    near_match_policy: notify
```

---

## Demo app

[`examples/demo`](examples/demo) is a bootable Rails 7.2 app with intentionally seeded findings — every detector trips at least once. Clone, `bin/setup`, `bin/rails server`, then visit `/`, `/broken`, and `/rails/lookbook` to see the auto-registered Guardrails panel. `bundle exec rake ui_guardrails:audit` runs the full audit against the seeded tree. See [`examples/demo/README.md`](examples/demo/README.md).

---

## Status & roadmap

- **V0** (foundation) — ✅ shipped
- **V1** (polish + ecosystem) — ✅ shipped
- **V2** (advanced) — ✅ shipped (cross-codebase patterns, class-itis, visual diff via snap_diff-capybara)

Full status table and decision log: [`doc/ROADMAP.md`](doc/ROADMAP.md).

---

## Development

```bash
bundle install
bundle exec rspec        # 883 examples
```

Real-world signal lives in `examples/demo` (integration spec) and in the dogfood patches against four real codebases (Patchvault, Talos, Forem, Avo — see `CHANGELOG.md` for what each round caught).

Issues and PRs: <https://github.com/meticulous/guardrails>

---

## Credits

- [Modern Web Guidance](https://developer.chrome.com/docs/modern-web-guidance), by Google Chrome and its contributors with the Microsoft Edge, Mozilla Firefox and MDN teams (Apache-2.0; guides CC BY 4.0). Feed Ramp installs it with its own installer and points agents at it; none of it is bundled.
- [Herb](https://github.com/marcoroth/herb), the ERB parser every template detector is built on.

---

## License

MIT
