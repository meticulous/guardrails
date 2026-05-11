# Guardrails

A Rails toolset that prevents UI drift in AI-assisted applications. Static audits over your views, components, stylesheets, JS controllers, and tokens — surfacing the kinds of inconsistencies that compound silently as an AI assistant ships code faster than design-system discipline can keep up.

Built and maintained by [Meticulous](https://meticulous.com).

**Current release:** 0.8.0 — V0 + V1 + V2 complete (see [`doc/ROADMAP.md`](doc/ROADMAP.md)).

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

The gem is not yet published to RubyGems — pin to the git source until it is:

```ruby
# Gemfile
group :development, :test do
  gem "guardrails", github: "meticulous/guardrails", tag: "v0.8.0"
end
```

```bash
bundle install
bundle exec rake guardrails:init       # writes guardrails.yml, scaffolds MQs
bundle exec rake guardrails:audit      # run the full audit
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
  rake -f ~/code/guardrails/lib/tasks/guardrails.rake \
  guardrails:audit
```

Every rake task accepts the same env vars in sidecar mode as in-project. The tasks default `root` to `Rails.root` when Rails is loaded, else `Dir.pwd` — so just run from the target app's root.

---

## Quick start

```bash
# One-time setup — detects your token stack, writes guardrails.yml,
# scaffolds prefers-color-scheme media queries if your stylesheet
# doesn't already have them. Interactive when on a TTY; CI-safe
# default fallback otherwise.
bundle exec rake guardrails:init

# Full audit — exits 1 on any violation.
bundle exec rake guardrails:audit

# Get a markdown checklist of fixable findings:
SUGGEST=1 bundle exec rake guardrails:audit
# → writes doc/guardrails-suggestions-{TIMESTAMP}.md

# Auto-fix raw_color and tailwind_arbitrary where a token matches:
APPLY=1 bundle exec rake guardrails:audit
```

---

## Tasks at a glance

| Task | What it does |
|---|---|
| `guardrails:init` | Stack detection, writes `guardrails.yml`, scaffolds prefers-color-scheme / prefers-contrast media queries. Refuses to overwrite an existing config — `FORCE=1` overrides. |
| `guardrails:audit` | Runs every detector — view drift, stimulus, partial similarity, view-components, a11y, cross-codebase patterns, class-itis. Exits 1 on violations. |
| `guardrails:icons` | Generates an SVG sprite from `app/assets/images/icons/`, flags inline `<svg>` in views, reports unused icons. |
| `guardrails:tokens` | Parses your color and type-scale tokens (CSS vars / SCSS vars / Tailwind v3 config / Tailwind v4 `@theme`), reports hex literals in stylesheets that should reference a token. |
| `guardrails:a11y:deep` | Reads axe-core JSON output and folds it into the unified report. Doesn't run axe itself (no Capybara / headless Chrome runtime deps) — point it at axe output your existing tooling produces. |
| `guardrails:visual:deep` | Consumes screenshot-diff tool output (snap_diff-capybara today; BackstopJS in flight, [#15](https://github.com/meticulous/guardrails/issues/15)) and reports visual regressions. Same parse-only design — your existing test toolchain runs screenshots; Guardrails reports. |

---

## Detectors

### View-level drift (`guardrails:audit`)

Static AST walk over every `.html.erb` under `app/views/` and `app/components/` (via [Herb](https://github.com/marcoroth/herb), the ERB-aware parser):

| Detector | Catches |
|---|---|
| `inline_style` | `<div style="…">` — inline styles bypass tokens entirely. |
| `raw_color` | Hex / rgb literals in color-bearing attributes (`fill`, `stroke`, `color`, `bgcolor`, `background`, `data-*color*`, etc.). |
| `tailwind_arbitrary` | `bg-[#fa3]`, `text-[14px]`, `p-[7px]` — arbitrary values that bypass the theme. |
| `helper_recommended` | `<button>` / `<a>` wrapping `<%= … %>` ERB output. Suggests `tag.button` / `link_to` / `button_to` for clean accessible names. Skips elements that already have `aria-label`. |
| `image_alt` / `button_name` / `link_name` / `input_label` | The four most common static a11y misses (see [`doc/A11Y.md`](doc/A11Y.md)). |

### Suggest mode and auto-fix

- `SUGGEST=1 rake guardrails:audit` writes `doc/guardrails-suggestions-{TIMESTAMP}.md` — a markdown checklist with one `[ ]` per fixable finding, the rule that fired, and the proposed replacement (closest token by exact match, else near-match within a configurable channel-distance).
- `APPLY=1 rake guardrails:audit` auto-fixes `raw_color` (→ `var(--token)`) and `tailwind_arbitrary` (→ Tailwind theme color shorthand) when a matching token exists. Near-match auto-fix is gated by `near_match_policy` in `guardrails.yml` (`fix` / `leave` / `notify`).

### Tokens

`Guardrails::Tokens` parses every token source it can find:

- CSS custom properties in your configured `colors_file`
- SCSS variables in the same
- Tailwind v3 `tailwind.config.js` — flat colors and nested scales (`gray.50` → `gray-50`)
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
VISUAL_DIFF=1 bundle exec rake guardrails:audit
```

Or standalone via `rake guardrails:visual:deep`. Parse-only — same trade as deep a11y, no Capybara/Chromium runtime deps in the gem. BackstopJS adapter tracked in [#15](https://github.com/meticulous/guardrails/issues/15). See [`doc/VISUAL-DIFF.md`](doc/VISUAL-DIFF.md).

### Deep a11y via axe-core JSON (0.6.0)

`Guardrails::A11yDeep` consumes axe-core JSON output and folds findings into the unified report:

```bash
npx @axe-core/cli http://localhost:3000/ --save axe.json
AXE_JSON=axe.json bundle exec rake guardrails:audit
```

Or standalone via `rake guardrails:a11y:deep`. Stays parse-only — your existing test toolchain runs axe (axe-core-rspec, the CLI, Puppeteer, a CDP script — anything that emits axe v4 JSON), Guardrails provides the merge + report. See [`doc/A11Y.md`](doc/A11Y.md).

### Lookbook auto-panel (0.5.0)

When [Lookbook](https://lookbook.build) is in the Gemfile, Guardrails auto-registers a `:guardrails` panel that appears next to every preview's Source / Notes panels. The panel renders `Guardrails::Lookbook::ComponentReport#for(component_class_name)` — drift in the template, orphan slots, similar templates — inline. Host apps override by dropping their own partial at `app/views/lookbook_panels/_guardrails.html.erb`. See [`doc/LOOKBOOK.md`](doc/LOOKBOOK.md).

---

## Output

Every task prints a human-readable text report by default and exits 1 when violations or failing findings exist. For machine consumption:

```bash
FORMAT=json bundle exec rake guardrails:audit > findings.json
```

The JSON payload has a `summary:` block with finding counts per category plus per-detector arrays — see the rake task source for the exact shape.

### Common env vars

| Var | Effect |
|---|---|
| `SUGGEST=1` | Write the markdown checklist alongside the text report. |
| `APPLY=1` | Auto-fix raw_color + tailwind_arbitrary where tokens match. |
| `FORMAT=json` | Emit one JSON document to stdout (all other audit output is suppressed). |
| `FORCE=1` | Bypass `init`'s refuse-to-overwrite default. |
| `AXE_JSON=path` | Fold axe-core findings into the unified report. |
| `VISUAL_DIFF=1` | Fold visual-diff findings into `guardrails:audit`. Embedded installs can flip this on permanently via `Guardrails.configure { \|c\| c.visual_diff.enabled = true }`. |
| `VISUAL_DIFF_DIR=path` / `VISUAL_DIFF_THRESHOLD=0.02` | Tune the visual-diff snap_diff adapter and mismatch threshold. |
| `SIMILARITY_THRESHOLD=0.85` | Override the partial-similarity Jaccard threshold. |
| `PATTERN_MIN_SIZE=8` / `PATTERN_MIN_OCCURRENCES=4` | Tune the cross-codebase pattern detector. |
| `CLASSITIS_MIN_CLASSES=6` / `CLASSITIS_MIN_OCCURRENCES=4` | Tune the class-itis detector. |

---

## CI

The audit task is a single shell command:

```yaml
# .github/workflows/ci.yml
- name: Guardrails audit
  run: bundle exec rake guardrails:audit
```

For richer integration:

```yaml
- name: Guardrails audit (JSON)
  run: bundle exec rake guardrails:audit FORMAT=json > findings.json
  continue-on-error: true

- name: Upload findings
  uses: actions/upload-artifact@v4
  with:
    name: guardrails-findings
    path: findings.json
```

---

## Configuration

`guardrails.yml` at the repo root. `guardrails:init` writes a sensible default after detecting your stack — what's below is annotated to show every available key:

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

[`examples/demo`](examples/demo) is a bootable Rails 7.2 app with intentionally seeded findings — every detector trips at least once. Clone, `bin/setup`, `bin/rails server`, then visit `/`, `/broken`, and `/rails/lookbook` to see the auto-registered Guardrails panel. `bundle exec rake guardrails:audit` runs the full audit against the seeded tree. See [`examples/demo/README.md`](examples/demo/README.md).

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
bundle exec rspec        # 453 examples
```

Real-world signal lives in `examples/demo` (integration spec) and in the dogfood patches against four real codebases (Patchvault, Talos, Forem, Avo — see `CHANGELOG.md` for what each round caught).

Issues and PRs: <https://github.com/meticulous/guardrails>

---

## License

MIT
