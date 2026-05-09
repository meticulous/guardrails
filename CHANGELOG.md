# Changelog

All notable changes to Guardrails will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/meticulous/guardrails/compare/v0.1.1...HEAD
[0.1.0]: https://github.com/meticulous/guardrails/releases/tag/v0.1.0
