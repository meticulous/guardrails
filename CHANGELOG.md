# Changelog

All notable changes to Guardrails will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-05-10

Minor release adding the **class-itis** detector — the second V2 audit. Surfaces the AI-assisted-Rails failure mode of identical multi-class utility soup copy-pasted onto the same tag across many views, when the codebase already has (or should have) a shared component or `@apply` rule for it.

### Added

- **`Guardrails::ClassItis` audit.** Walks every element across `app/views` and `app/components`, groups by `(tag, sorted-class-list)`, and reports tuples appearing in 3+ places with at least 5 distinct classes. Class lists are sorted + uniq'd so a re-ordered or repeat-token attribute doesn't fragment or inflate the count.
- **ERB-aware extraction.** Only the static portion of `class="..."` is fingerprinted; `<%= variant %>` fragments are dropped (we can't know what they'll render). Mixed-static-and-ERB attributes still surface their literal classes.
- **Wired into `rake guardrails:audit`** in both text and JSON modes. Env overrides: `CLASSITIS_MIN_CLASSES` (default 5), `CLASSITIS_MIN_OCCURRENCES` (default 3). Findings are advisory — they do not bump the exit code, since "this class list repeats" is a refactor suggestion, not a violation.

Distinct from `CrossCodebasePatterns` (which fingerprints structural element shape, ignoring classes) and `PartialSimilarity` (which Jaccard-compares whole existing partials).

### Verified

Real-world signal across four codebases:

| Repo | Clusters | Top finding |
|---|---|---|
| Forem | 27 | A `<h1>` with 8 utility classes (`fs-3xl fw-bold l:fs-5xl lh-tight mb-4 mt-0 s:fs-4xl s:fw-heavy`) repeats 27 times — clean candidate for a heading partial |
| Patchvault | 1 | A `<div class="corner-ribbon grey shadow sticky top-right">` repeats 7 times |
| Avo | 1 | A tooltip `<div>` with 9 classes repeats 3 times (low total because Avo is ViewComponent-driven) |
| Talos | 0 | Classes are largely ERB-fragmented (`content_tag` style), so static fingerprinting finds no exact-match repeats — confirms the detector cleanly skips dynamic class lists |

[0.4.0]: https://github.com/meticulous/guardrails/releases/tag/v0.4.0

## [0.3.0] - 2026-05-10

Minor release adding a new cross-codebase pattern detector. Distinct from `PartialSimilarity` (which compares existing partials to each other), this audit looks at *any* element subtree in *any* view and surfaces shapes that repeat 3+ times — concrete refactor candidates for shared partials or ViewComponents.

### Added

- **`Guardrails::CrossCodebasePatterns` audit.** Walks every `app/views/**/*.html.erb` and `app/components/**/*.html.erb` file, fingerprints each subtree's tag-only shape (e.g. `article(header(h2),section(p,p),footer(a))`), and reports shapes that appear 3+ times with at least 5 element nodes. Findings include file + line for every occurrence so you can jump straight to extraction candidates. Reuses the same path-component ignore list as the main audit (vendor, node_modules, tmp, public, log, `*_mailer/`, `mailer/`).
- **Wired into `rake guardrails:audit`** in both text and JSON modes. New env overrides: `PATTERN_MIN_SIZE` (default 5) and `PATTERN_MIN_OCCURRENCES` (default 3). Findings are advisory — they do not bump the exit code, since "this shape repeats" is a suggestion, not a violation.
- **Redundant-nested dedupe.** When a table repeats N times, the naive walk produces three patterns with identical counts (`table(thead(tr(...)),tbody)`, `thead(tr(...))`, `tr(...)`). The detector drops the inner shapes when they're dominated by an outer pattern (same count, file containment, proper sub-shape) so only the actionable extraction candidate surfaces.

### Verified

Real-world signal across four codebases:

| Repo | Patterns (after dedupe) | Top finding |
|---|---|---|
| Patchvault | 24 | An admin-card pattern (h2-link header + two h3/div pairs + button group) repeats 8 times |
| Talos | 90 | A 5-column table (`table(thead(tr(th,th,th,th,th)),tbody)`) repeats 26 times |
| Forem | 50 | A `ul(li(a),li(a),li(a))` nav structure repeats 10 times |
| Avo | 0 | ViewComponent-driven — no static ERB to compare (expected) |

[0.3.0]: https://github.com/meticulous/guardrails/releases/tag/v0.3.0

## [0.2.3] - 2026-05-10

Patch release driven by dogfooding 0.2.2 against [Avo](https://github.com/avo-hq/avo) (Tailwind admin framework) and [Forem](https://github.com/forem/forem) (content platform). Three real-world layout/path patterns fixed.

### Fixed

- **`StimulusAudit` finds controllers under any `app/javascript/**/controllers/` or `app/frontend/controllers/` layout.** Previously hardcoded to `app/javascript/controllers/`, so Avo's `app/javascript/js/controllers/` (and Vite Rails's `app/frontend/controllers/`) reported every controller as orphaned. Controller-name derivation now anchors on the deepest `controllers/` segment in the path, so namespacing still works correctly across all four common layouts.
- **`Tokens` hints when `tailwind.config.js` uses `presets: [...]` import.** The Tailwind v3 parser is regex-based and can't follow JS imports, so preset-style configs (Avo, many shared-config setups) produce zero tokens — and the previous output looked like a parser bug. The new hint surfaces alongside the 0-tokens line: "tailwind.config.js uses a `presets:` import; only the literal config file is parsed (we don't evaluate JS). Define non-color tokens in v4 `@theme` blocks for cross-tool token visibility."
- **Audit now also implicit-ignores plain `mailer/` directories** (Devise's `app/views/devise/mailer/` convention), not just `*_mailer/` paths from the 0.2.1 fix. The regex anchors on the segment, so lookalikes like `_mailer_partial/` still correctly don't match.

### Verified

| Repo | Effect |
|---|---|
| Avo | Stimulus: 39 orphaned / 0 dead → 17 orphaned / 31 dead (real findings now visible). Tokens output gains the preset hint. |
| Forem | Audit: 986 → 960 violations (26 false positives in `app/views/devise/mailer/` removed) |

[0.2.3]: https://github.com/meticulous/guardrails/releases/tag/v0.2.3

## [0.2.2] - 2026-05-10

UX patch — two report-clarity fixes following the Talos dogfood. No detection-logic changes.

### Changed

- **`PartialSimilarity` collapses pairwise findings into connected-component groups.** When 8 templated partials are all pairwise similar (e.g. the `public_activity` engine pattern), the report previously emitted C(8,2) = 28 noisy pair lines. It now emits one "Group of 8 templates" entry with the full file list and observed score range. The raw pair count is still reported in the header. On Talos this drops the visible output from 313 pair lines to 57 groups across 199 files — 5.5× reduction in noise. Single pairs (size-2 components) keep the original `file_a ↔ file_b` format.
- **`Tokens` error message names the missing config key and points at remediation.** When `guardrails.yml` references a `colors_file` / `type_scale_file` that doesn't exist on disk, the message now identifies the specific YAML key and suggests "Edit guardrails.yml to point at your real token file, or set FORCE=1 and re-run guardrails:init."

### Added

- `PartialSimilarity#group_findings` — exposed publicly so external tooling can consume the structured group form (returns `{ files:, score_min:, score_max:, pair_count: }` per component).

[0.2.2]: https://github.com/meticulous/guardrails/releases/tag/v0.2.2

## [0.2.1] - 2026-05-10

Patch release driven by dogfooding 0.2.0 against [Talos](https://github.com/Knightsbridge/talos) — a 12-year Rails 8 app mid-port to ViewComponent (807 ERB files, 33 components, no Tailwind). Two specific false-positive patterns surfaced; both fixed.

### Fixed

- **`helper_recommended` no longer fires on elements that already declare `aria-label` or `aria-labelledby`.** The pattern in the wild is icon buttons (`<button aria-label="Search"><%= render IconComponent.new %></button>`) where accessibility is explicitly handled on the literal tag and the suggestion to switch to `tag.button(label, ...)` is just idiom noise. 16 of 44 findings on Talos were this exact case.
- **Audit auto-ignores `*_mailer/` view directories.** Email clients require inline styles, so flagging mailer views as design-system drift is incorrect by design. The new `IMPLICIT_IGNORE_PATTERNS` regex list matches `\A\w+_mailer\z` against any path component, alongside the existing literal `IMPLICIT_IGNORE` set (vendor / node_modules / tmp / public / log). 24 of 109 inline_style findings on Talos were in mailer views.

### Verified against Talos

| Metric | 0.2.0 | 0.2.1 |
|---|---|---|
| Audit total | 153 | 117 (−36) |
| inline_style | 109 | 86 (−23) |
| helper_recommended | 44 | 31 (−13) |
| a11y total | 59 | 56 (−3) |
| Stimulus / similarity / VC findings | unchanged | unchanged |

[0.2.1]: https://github.com/meticulous/guardrails/releases/tag/v0.2.1

## [0.2.0] - 2026-05-09

Foundation upgrade — every audit detector now walks a real ERB AST via the [Herb](https://herb-tools.dev) parser instead of regex-scanning masked source. Behavior preserved across the existing test corpus (325/325 pass) with edge-case false positives eliminated.

### Added

- **Hard runtime dependency on `herb >= 0.10`.** Brings a proper HTML+ERB parser (the same parser the Rails team adopted in 2025) into Guardrails as the foundation for static analysis.
- **`Guardrails::ErbParser` module** — thin wrapper around `Herb.parse`. Exposes `parse(source)`, `each_node(node)`, `compact_children(node)`, and `start_position(node)` so detectors get a stable interface and parse failures degrade gracefully.

### Changed

Every detector that previously regex-masked source now walks the AST:

- **`inline_style`** — flags any `HTMLAttributeNode` whose name is `style`. No more dependence on `/\bstyle\s*=/` regex matching.
- **`raw_color`** — iterates each element's attributes, filters to color-bearing names (fill, stroke, color, bgcolor, background, flood/lighting/stop-color, plus `data-*color*` / `data-*colour*`), and scans only the static portion of the attribute value. Mixed values like `fill="<%= shade %>"` no longer false-flag.
- **`tailwind_arbitrary`** — walks `class` attributes and finds `[...]` patterns in their static text. Variant chains and dynamic class fragments handled cleanly.
- **`helper_recommended`** — checks `ERBContentNode#tag_opening` directly to distinguish `<%=` (output) from `<%` (control flow) and `<%#` (comments). The `<a>` href gate uses real attribute iteration.
- **`A11yAudit` (image_alt, button_name, link_name, input_label)** — now AST-driven. Multi-line elements parse exactly. The label-for lookup walks the document once per file and caches matched ids. The deferred-to-helper_recommended logic checks for actual `<%=` ERBContentNode children, not regex matches.
- **`PartialSimilarity` tokenizer** — emits tag tokens via AST traversal (open-tag → recurse body → close-tag) so the source-order shape matches the previous regex tokenizer. Void elements (img, input, br, etc.) produce one token, not two. Same Jaccard math, more accurate input.

### Removed

- `mask`, `mask_chars`, `scan_lines`, `inside_quoted_attribute?` — masking-pipeline helpers no longer needed.
- `ERB_BLOCK_PATTERN`, `HTML_COMMENT_PATTERN`, `ERB_OUTPUT_PATTERN`, `CLASS_ATTRIBUTE_DOUBLE`, `CLASS_ATTRIBUTE_SINGLE`, `COLOR_ATTRIBUTE_PATTERN` — pattern constants that drove the old scan flow. Surviving regexes (`HEX_LITERAL_PATTERN`, `RGB_LITERAL_PATTERN`, `ARBITRARY_VALUE_PATTERN`, `INLINE_STYLE_PATTERN`) operate on already-scoped strings extracted via the AST, not on raw file content.

### Fixed (real false-positive cases the AST handles cleanly)

- Multi-line HTML comments containing inline styles no longer false-flag (`<!--<p style="...">...</p>-->` spanning many lines).
- ERB output strings containing markup-shaped content (`<%= "<button></button>" %>`) no longer surface as bogus elements.
- Attribute values containing `>` or quotes are tokenized correctly.
- Patchvault audit count: 83 → 82 (one false-positive multi-line commented-out style); a11y count: 48 → 47 (one regex edge case).

### Migration notes

No public API changes. `guardrails.yml` config keys are unchanged. CLI / rake task surface is identical. Existing tests pass without modification. If you've been pinning `guardrails ~> 0.1`, update to `~> 0.2`.

[0.2.0]: https://github.com/meticulous/guardrails/releases/tag/v0.2.0

## [0.1.1] - 2026-05-09

Patch release driven by dogfooding 0.1.0 against [Patchvault](https://github.com/jathayde/patchvault) — a 12-year-old Rails 8 app on Sprockets/Propshaft with no Tailwind. Surfaced and fixed five real issues.

### Fixed

- **`StackDetector` crashed on non-ASCII content.** `Pathname#read` uses the default external encoding (US-ASCII on some setups). Now forces `Encoding::UTF_8` like `Audit` / `Tokens` / `Icons` already did.
- **HTML comments weren't masked before audit detectors ran**, so `<!--<p style="color: red">-->` flagged as `inline_style`. Both `Audit` and `A11yAudit` now strip `<!-- ... -->` first (preserving line/column positions) before scanning.
- **Dead-icon detection only matched `#icon-NAME` sprite references**, reporting 100% of icons as "unused" on projects that use traditional `image_tag`/`asset_path`. Now also recognizes `image_tag "foo.svg"`, `asset_path("foo.svg")`, `image_path/url(...)`, and CSS `url(/icons/foo.svg)` references across views, components, stylesheets, and JS.
- **Strategy detection ranked `raw_hex` over `scss_variables` / `css_custom_properties` on near-ties.** A project with 17 SCSS-variable files and 19 raw-hex files was setup as `raw_hex` and bailed on configuring `colors_file`. The rule now prefers any token system over `raw_hex` regardless of file counts; `raw_hex` only wins when no token usage exists at all.
- **`Audit`, `StackDetector`, and `Tokens` now implicit-ignore `vendor/`, `node_modules/`, `tmp/`, `public/`, `log/` path components anywhere in the tree.** Scanners no longer pull in `app/assets/stylesheets/vendor/jquery-ui/_theme.css` and similar third-party noise. User-configured `audit.ignore` paths in `guardrails.yml` are additive (matched as exact paths or directory prefixes — not shell globs).

### Performance

Full audit on a 496-ERB-file Rails repo runs in ~0.5s. Init / icons / tokens each finish in &lt;0.5s. Well under the PRD's 30-second target.

[0.1.1]: https://github.com/meticulous/guardrails/releases/tag/v0.1.1

Initial public release. Ships V0 + most of V1 from the [roadmap](doc/ROADMAP.md).

### Added — `rails guardrails:audit`

- View & component drift detection: inline `style=` attributes, raw hex/rgb in color-bearing attributes (fill, stroke, color, bgcolor, background, flood/lighting/stop-color, data-*color*), Tailwind arbitrary class values (`bg-[#fa3]`).
- ERB output (`<% %>`) is masked before scanning so dynamic content doesn't false-positive; UTF-8 file reads handle multi-byte chars.
- `helper_recommended` detector flags `<button>` and `<a href>` wrapping `<%=` output and suggests `tag.button` / `button_to` / `link_to`. The corresponding a11y rules (`button_name`, `link_name`) skip the same case so users get one actionable suggestion.
- Stimulus audit for orphaned (referenced in HTML, no JS file) and dead (JS file, never referenced) controllers. Recognizes both `data-controller="..."` and Ruby helpers like `tag.div(data: { controller: "..." })`.
- ViewComponent audit: missing previews, orphan slot declarations, and structural similarity between sidecar templates.
- ERB partial structural similarity via 3-gram tag-sequence Jaccard (default threshold `0.7`, `SIMILARITY_THRESHOLD` env override).
- Static a11y checks: `image_alt`, `button_name`, `link_name`, `input_label`. axe-core integration documented at [doc/A11Y.md](doc/A11Y.md) for users who want runtime coverage.
- `SUGGEST=1` emits `doc/guardrails-suggestions-{TIMESTAMP}.md` — checklist with concrete token-aware replacements. Tailwind utility names preserve variant chains (`lg:hover:bg-primary`); CSS-var fallback for tailwind_arbitrary stays in arbitrary syntax (`bg-[var(--primary)]`).
- `APPLY=1` rewrites in source: `raw_color` → `var(--token)` (CSS custom property tokens only), `tailwind_arbitrary` → `bg-tokenname` (Tailwind theme tokens only). Right-to-left within a line; verifies expected text at column before writing.
- `FORMAT=json` unified output across the main audit, Stimulus audit, partial similarity, ViewComponent audit, and a11y checks.
- `audit.scan_paths` and `audit.ignore` honored from `guardrails.yml`.

### Added — `rails guardrails:init`

- Detects stylesheet stack (`css_custom_properties` / `scss_variables` / `raw_hex` / `none`) and writes `guardrails.yml` with strategy-aware token paths.
- Interactive prompts (TTY): `near_match_policy`, `near_match_threshold`, `scan_paths`, `ignore` paths (matched as exact paths or directory prefixes). Non-TTY (CI) falls back to defaults silently.
- Scaffolds `@media (prefers-color-scheme: dark)` and `@media (prefers-contrast: more)` stubs into the configured colors file when missing.
- Refuses to overwrite an existing `guardrails.yml`; `FORCE=1` overrides and re-runs MQ scaffolding. Prompts are skipped when overwrite is refused.

### Added — `rails guardrails:icons`

- Generates a deterministic `<symbol>`-based SVG sprite from the configured icons directory.
- Detects inline `<svg>` blocks in views that should be sprite references.
- Reports dead icons (sprite has them, no view uses `#icon-name`) and unknown references (view points at icons not in source).

### Added — `rails guardrails:tokens`

- Parses CSS custom properties and SCSS variables from `tokens.colors_file` and `tokens.type_scale_file`.
- Auto-discovers Tailwind v4 `@theme {}` directives via the existing CSS scanner.
- Auto-discovers Tailwind v3 `tailwind.config.js` at the repo root, parsing `theme.colors` / `theme.extend.colors` (colors-only by design — non-color tokens belong in v4 `@theme`).
- Strips CSS/SCSS comments before scanning so commented examples don't false-positive.
- Reports stylesheet drift with hex normalization (case + short-form expansion + alpha stripping) and matches against any token source.

### Added — Configuration

- `tokens.near_match_policy` (`notify` / `fix` / `leave`) controls near-match behavior in suggest and auto-fix modes.
- `tokens.near_match_threshold` (default `4`) — max per-channel R/G/B difference (0..255) for a value to count as a near match. ConfigWriter emits a footer comment explaining the scale (0 = exact only, 4 = visually similar, 10+ = loose).

### Added — Lookbook integration

- `Guardrails::Lookbook::ComponentReport` returns per-component findings as a Hash for rendering inside Lookbook panels. See [doc/LOOKBOOK.md](doc/LOOKBOOK.md) for panel wire-up.

### Added — Sample app

- `examples/demo/` directory tree (Rails-shaped, not a bootable server) with seeded violations across every audit. Backed by `spec/integration/demo_app_spec.rb` asserting concrete counts.

### Documentation

- [`doc/PRD.md`](doc/PRD.md) — product requirements.
- [`doc/ROADMAP.md`](doc/ROADMAP.md) — V0 / V1 / V2 status and decisions.
- [`doc/LOOKBOOK.md`](doc/LOOKBOOK.md) — Lookbook panel integration guide.
- [`doc/A11Y.md`](doc/A11Y.md) — static a11y rules and the axe-core layering recipe for runtime coverage.

[Unreleased]: https://github.com/meticulous/guardrails/compare/v0.2.3...HEAD
[0.1.0]: https://github.com/meticulous/guardrails/releases/tag/v0.1.0
