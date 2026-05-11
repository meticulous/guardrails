# Guardrails — Roadmap

**Status:** V0 finished, V1 mostly shipped (Lookbook auto-registration shipped 0.5.0, deep a11y shipped 0.6.0; sample-app boot remains), V2 2/3 done (cross-codebase patterns + class-itis)
**Last updated:** 2026-05-10

## Context

Guardrails is a Ruby gem that prevents UI drift in Rails apps — particularly drift introduced by AI coding assistants that generate UI faster than design-system consistency can be maintained. The gem is also the conceptual scaffolding for the Rails World talk. The talk is **concept-led, not demo-led**, so the gem is the durable artifact rather than a live-demo dependency.

This doc tracks shipped vs. planned scope and parks remaining unknowns. V0 + most of V1 landed in PR #1; 0.2.x patches refined detectors against four real codebases (Talos, Avo, Forem, Patchvault); 0.3.0 added cross-codebase structural pattern detection; 0.4.0 added the class-itis detector.

---

## V0 — Foundation

### Audit (`rails guardrails:audit`)

| Item | Status | Notes |
|---|---|---|
| Inline `style=` attributes | ✅ shipped | |
| Hex / rgb color literals | ✅ shipped | Scoped to color-bearing attributes (fill, stroke, color, bgcolor, background, flood/lighting/stop-color, data-*color*) after Copilot review caught href="#section" false positives |
| Tailwind arbitrary values (`bg-[#fa3]`) | ✅ shipped | Reported once as `tailwind_arbitrary`, not double-flagged as raw_color |
| Hardcoded `font-size` / `line-height` | ❌ dropped as standalone | Folded into inline_style + tailwind_arbitrary detectors. Type-scale awareness lives in suggest mode token matching |

### Suggest mode (`SUGGEST=1`)

| Item | Status | Notes |
|---|---|---|
| Markdown checklist artifact | ✅ shipped | `doc/guardrails-suggestions-{TIMESTAMP}.md` |
| Closest-token matching | ✅ shipped | Exact + near-match (channel-distance ≤ 4) |
| Per-violation `[ ]` checkbox + rule + replacement | ✅ shipped | |
| Type-scale matching | ✅ shipped | `text-[1rem]` matches a defined `--text-base: 1rem` token |

### Auto-fix (`APPLY=1`)

| Item | Status | Notes |
|---|---|---|
| `raw_color` exact-match rewrite to `var(--token)` | ✅ shipped | Right-to-left within line; verifies expected text at column before writing |
| `raw_color` near-match rewrite | ✅ shipped | Gated on `near_match_policy: fix` in guardrails.yml |
| `tailwind_arbitrary` auto-fix | ✅ shipped | Replaces `bg-[#hex]` with `bg-tokenname` when a `:tailwind` theme token matches by value. Variant prefixes (`lg:hover:`, `[&>div]:`) preserved |
| `inline_style` auto-fix | ❌ deferred | Structural rewrite, not value swap |
| `font-size` auto-fix | ❌ deferred | Same constraint as inline_style |

### Icons (`rails guardrails:icons`)

| Item | Status |
|---|---|
| SVG sprite generation | ✅ shipped |
| Inline `<svg>` detection in views | ✅ shipped |
| Dead-icon report | ✅ shipped |

### Init / analysis (`rails guardrails:init`)

| Item | Status | Notes |
|---|---|---|
| Stack detection (CSS-vars / SCSS / raw-hex) | ✅ shipped | |
| `guardrails.yml` writing with sensible defaults | ✅ shipped | |
| `prefers-color-scheme` + `prefers-contrast` MQ scaffolding | ✅ shipped | Skipped if ConfigWriter refuses to overwrite |
| Interactive prompts (TTY) | ✅ shipped | near_match_policy / near_match_threshold / scan_paths / ignore paths (matched as exact paths or directory prefixes — not shell globs). CI-safe non-TTY fallback to defaults. Skipped entirely when config exists and FORCE=1 isn't set |
| Refuse-overwrite by default | ✅ shipped | |
| `FORCE=1` to overwrite + re-scaffold MQs | ✅ shipped | |

### Tokens (`rails guardrails:tokens`)

| Item | Status | Notes |
|---|---|---|
| Parse CSS custom properties + SCSS variables from `colors_file` | ✅ shipped | |
| Parse `type_scale_file` alongside `colors_file` | ✅ shipped | |
| Tailwind v4 `@theme {}` blocks | ✅ shipped | Goes through the existing CSS custom property scanner |
| `tailwind.config.js` (v3) regex parsing | ✅ shipped | Best-effort: flat colors, nested scales (gray.50 → gray-50), spread/function values skipped |
| Stylesheet drift scan with comment stripping | ✅ shipped | |
| Hex normalization (case + short form + alpha) | ✅ shipped | |
| Drift matching against Tailwind theme colors | ✅ shipped | |

### Stimulus audit

| Item | Status | Notes |
|---|---|---|
| Orphan controllers (referenced, no JS file) | ✅ shipped | |
| Dead controllers (JS file, never referenced) | ✅ shipped | |
| Ruby helper syntax detection | ✅ shipped | `tag.div(data: { controller: "foo" })` and hash-rocket variants |

### CI integration

| Item | Status | Notes |
|---|---|---|
| Exit codes (0 clean, 1 violations) | ✅ shipped | |
| `FORMAT=json` machine-readable output | ✅ shipped | Unified across all sub-audits |
| `--strict` flag | ❌ dropped | No semantic distinction beyond exit-1-on-violations default. Revisit if/when warning vs error severities emerge |

---

## V1 — Polish + Differentiation

| Item | Status | Notes |
|---|---|---|
| ViewComponent preview detection | ✅ shipped | |
| ViewComponent slot validation | ✅ shipped | Known limit: code-only components (`def call`) flag declared slots as orphans |
| Component-shape similarity | ✅ shipped | n-gram Jaccard, default threshold 0.7. PartialSimilarity scans both `_*.html.erb` partials and `*_component.html.erb` VC templates |
| Lookbook integration | ✅ shipped (0.5.0) | `Guardrails::Lookbook::ComponentReport` data API + Railtie auto-registers the `:guardrails` panel when Lookbook is loaded; partial ships inside the gem. Host can override the partial via standard view-path precedence. |
| ERB-partial structural similarity | ✅ shipped | Same PartialSimilarity engine |
| A11y integration | ✅ shipped (0.6.0) | Static checks shipped (image_alt, button_name, link_name, input_label). button_name and link_name skip when the element body wraps ERB output — those cases get a `helper_recommended` finding instead. **Deep mode shipped via `Guardrails::A11yDeep`** — consumes axe-core JSON output (single or multi-page) and folds findings into the unified report. `AXE_JSON=path/to/axe.json bundle exec rake guardrails:audit` or `rake guardrails:a11y:deep`. Stayed parse-only (no Capybara / headless Chrome runtime deps) per the original size constraint. |
| `helper_recommended` detector | ✅ shipped | Flags `<button>` / `<a>` wrapping ERB output and suggests `tag.button` / `button_to` / `link_to`. Pairs with the a11y skip for the same case |
| Targeted auto-fix | ✅ shipped | See V0 auto-fix table; tailwind_arbitrary now also auto-fixes when a `:tailwind` theme token matches |
| Sample app in `examples/` | 🟡 partial | Fake-Rails-app directory tree (no Gemfile, no bootable server). Serves as integration-test surface and talk material; doesn't `rails server` |

---

## V2 — Advanced

| Item | Status | Notes |
|---|---|---|
| Cross-codebase pattern detection | ✅ shipped (0.3.0) | `Guardrails::CrossCodebasePatterns` — fingerprints element subtree shapes, surfaces shapes appearing 3+ times across `app/views` and `app/components`. Drops redundant nested patterns dominated by an outer shape. Verified against Patchvault (24 patterns), Talos (90), Forem (50), Avo (0, expected — ViewComponent-driven). |
| Class-itis reduction | ✅ shipped (0.4.0) | `Guardrails::ClassItis` — groups elements by `(tag, sorted-class-list)`, reports tuples with >= 5 classes appearing in >= 3 places. ERB-driven fragments are dropped; static portion only. Verified against Forem (27 clusters incl. an `<h1>` repeating 27 times), Patchvault (1), Avo (1), Talos (0 — classes mostly ERB-fragmented). |
| Visual diff integration | ❌ pending | Screenshot tooling; revisit once auto-fix matures and a stable visual-regression target is chosen (Percy / Chromatic / homegrown). |

---

## Decisions Captured

| Question | Decision |
|---|---|
| Tailwind arbitrary values | **In V0.** High signal even outside AI-coded apps. |
| ViewComponent vs ERB | **Uniform in V0.** Rich support in V1 with Lookbook docs. |
| Auto-fix | **Suggest in V0** via markdown checklist. **Targeted auto-fix in V1**: raw_color → `var(--token)` with `APPLY=1`. Broad auto-fix not committed. |
| VS Code extension | **Out of scope.** |
| Stimulus | **In V0.** |
| A11y | **Static checks in V0/V1.** axe-core full wrapper deferred — bundling Capybara + headless Chrome was too heavy; documented integration path instead. |
| Sample app | **Yes, fake-Rails-app structure** (not bootable). |
| Tailwind v4 | **Supported in V0** via `@theme` directives. |
| Tailwind v3 (`tailwind.config.js`) | **Supported in V0, colors-only by design.** Best-effort regex parsing of `theme.colors` / `theme.extend.colors`. Non-color tokens (spacing, fontSize, fontFamily, screens) are NOT extracted from v3 configs — projects that want non-color token coverage should migrate to Tailwind v4 `@theme {}` directives, which our existing CSS-custom-property scanner parses cleanly. |
| Suggestions-md location | `doc/guardrails-suggestions-{TIMESTAMP}.md`. |
| Near-match handling | Always *suggest* by default. Per-project policy in `guardrails.yml` (`fix` / `leave` / `notify`). |
| `--strict` flag | **Dropped from V0.** No distinction beyond default exit-1-on-violations until severity levels exist. |
| Standalone font-size detector | **Folded into inline_style + tailwind_arbitrary.** Type-scale awareness lives in suggest mode. |
| Near-match threshold | **Max per-channel R/G/B = 4 units (default).** Configurable per-project via `tokens.near_match_threshold` in `guardrails.yml`; ConfigWriter emits a footer comment explaining the scale (0/1/4/10/20+). |
| Init rerunnability | **Refuses overwrite by default; `FORCE=1` overrides.** Prompts are skipped entirely when overwrite is refused (no questions whose answers won't apply). |
| MQ scaffold conflicts | **Skip if any matching `@media` block already exists.** Don't augment partial blocks. |
| ERB-aware a11y | **Resolved via `helper_recommended` detector.** `<button>` / `<a>` wrapping ERB output trip the helper-recommendation rule (suggest `tag.button` / `link_to` etc.); the corresponding a11y rule (button_name / link_name) skips that case so users get one actionable suggestion, not two overlapping flags. |
| Tailwind utility-name auto-fix | **Shipped.** APPLY=1 rewrites `bg-[#hex]` to `bg-tokenname` against `:tailwind` theme tokens. Variant prefixes (`lg:hover:`, `[&>div]:`) preserved. Suggestion text falls back to `bg-[var(--name)]` when only a `:css_var` token matches (still arbitrary, but parameterized). |

---

## Sample App (`examples/`)

A fake-Rails-app directory tree (no Gemfile or `config/`, not bootable as a Rails server) that exercises every audit. Three roles:

1. **Integration test surface** — `spec/integration/demo_app_spec.rb` runs each audit and asserts concrete counts.
2. **Showcase / talk material** — clear contrast between `welcome/index.html.erb` (clean) and `welcome/broken.html.erb` (every detector finds at least one violation).
3. **Onboarding reference** — `examples/demo/README.md` explains what's seeded.

If a bootable Rails server is needed for the talk demo, that's a separate scaffolding step on top of this tree — not currently shipped.

---

## Open Questions

None currently. All four V1 follow-up questions have been resolved (see Decisions Captured below). Add new ones here as they emerge during V2 work.
