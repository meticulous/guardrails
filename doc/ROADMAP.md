# Guardrails — Roadmap

**Status:** Approved
**Last updated:** 2026-05-04

## Context

Guardrails is a Ruby gem that prevents UI drift in Rails apps — particularly drift introduced by AI coding assistants that generate UI faster than design-system consistency can be maintained. The gem is also the conceptual scaffolding for the Rails World talk. The talk is **concept-led, not demo-led**, so the gem is the durable artifact rather than a live-demo dependency. This means feature scope can be aspirational — V0 doesn't have to be talk-shippable in itself.

This roadmap captures decisions from the PRD open-questions discussion and parks remaining unknowns.

---

## V0 — Foundation

Core thesis: **detect drift, suggest fixes, hand the human the decision.**

### Audit (`rails guardrails:audit`)
- Scan `.html.erb`, ViewComponent templates, `.rb` component files
- Treat ERB and ViewComponent uniformly at this stage
- Detect:
  - Inline `style=` attributes
  - Hex / rgb color literals outside token files
  - Hardcoded `font-size` / `line-height` outside type scale
  - **Tailwind arbitrary values** (`bg-[#fa3]`, `text-[14px]`, etc.) — flag any `[...]` inside class strings

### Suggest mode (`--suggest`)
- For each violation, identify the closest matching token (`$color-primary-500`, `text-base`, etc.)
- Output: a **`doc/guardrails-suggestions-{TIMESTAMP}.md`** artifact with:
  - One section per file, grouped by violation type
  - Per-violation: file:line, current code snippet, suggested replacement, a `[ ]` checkbox
  - A header summary: total violations, suggestion count, files touched
- Workflow: dev reviews the markdown, applies changes manually, checks off boxes, commits the markdown alongside the change as an audit trail (or `.gitignore`s it — their call)
- No silent auto-fix in V0; human reviews and applies each suggestion

### Icons (`rails guardrails:icons`)
- SVG sprite generation from configured directory
- Detect inline SVGs that should be sprite refs
- Dead-icon report (sprite has it, no view references it)

### Init / analysis (`rails guardrails:init`)
First-run onboarding task. Analyzes the current stylesheet stack and configures the gem accordingly.

- Detect token strategy in use:
  - **CSS custom properties** → preferred path, configure as-is
  - **SCSS variables** → fine, configure as-is (don't force migration if the stack is committed)
  - **Manual hex colors / no token system** → recommend a migration path to CSS custom properties; offer to scaffold a starter token file
- Detect and scaffold modern media query support:
  - `@media (prefers-color-scheme: dark)`
  - `@media (prefers-contrast: more)`
  - If neither block exists, write empty stubs with `/* TODO: fill this in */` comments in the appropriate CSS file
- Interactive config prompts written to `guardrails.yml`:
  - Near-match auto-fix policy: **fix** / **leave** / **notify** (per-violation behavior when a hex value is close-but-not-exact to a defined token)
  - File scan paths, ignore globs, etc.

### Tokens (`rails guardrails:tokens`)
- Read `guardrails.yml` for color / type / spacing definitions
- Scan CSS / SCSS / Tailwind theme for non-matching values
- Read `tailwind.config.js` **and Tailwind v4 CSS-first `@theme` directives** as a token source (v4 is a hard target — Guardrails ships into v4 territory)

### Stimulus audit
- Orphaned controllers (declared in HTML, no JS file)
- Dead controllers (JS file, no HTML reference)

### CI integration
- Exit codes (0 clean, 1 violations)
- `--strict`, `--format json`

---

## V1 — Polish + Differentiation

- **ViewComponent-aware audits**: slot misuse, missing previews, component-shape similarity
- **Lookbook integration**: surface ViewComponent audit results inside Lookbook previews
- **ERB-partial structural similarity**: near-duplicate partial detection (not just naming)
- **A11y integration** — wrap an existing checker (axe-core via `axe-core-rspec` / `axe-core-capybara`, or Pa11y as fallback). Two modes:
  - **Default**: limited ruleset focused on design-system overlap — color contrast vs. tokens, aria on icon-only buttons (sprite output), focus styles using token values, heading hierarchy
  - **`--deep`**: full a11y ruleset for users who want Guardrails as a one-stop UI-quality tool
- **Targeted auto-fix** for low-risk, exact-match violations (e.g., `bg-[#0066ff]` → `bg-primary-500` when the hex matches a token exactly)
- **Sample/demo Rails app** in `examples/`

---

## V2 — Advanced

- **Class-itis reduction**: `@apply` / utility-extraction suggestions, or whatever the prevailing Tailwind 4 best-practice equivalent is by ship time
- **Cross-codebase pattern detection**: "this button shape appears 12 times — extract a component?"
- **Visual diff integration** with screenshot tooling (originally a non-goal; revisit once auto-fix exists)

---

## Decisions Captured

| Question | Decision |
|---|---|
| Tailwind arbitrary values | **In V0.** High signal even outside AI-coded apps. Suggest + targeted auto-fix in V0/V1. |
| ViewComponent vs ERB | **Uniform in V0.** Rich support for both in V1, with Lookbook integration. |
| Auto-fix | **Suggest in V0** via `guardrails-suggestions.md` checklist artifact. Targeted auto-fix in V1. Broad auto-fix not committed. |
| VS Code extension | **Out of scope.** |
| Stimulus | **In V0.** Frontend is frontend. |
| A11y | **In V1.** Wrap axe-core. Limited default ruleset (design-system overlap), `--deep` flag for full ruleset. Acceptable to slip to V2 if V1 scope tightens. |
| Sample app | **Yes, full Rails app in `examples/`.** Doubles as integration test surface and talk material. |
| Tailwind v4 | **Supported in V0.** Guardrails ships Q3/Q4 2026 — must read v4 CSS-first `@theme` config alongside legacy `tailwind.config.js`. |
| Suggestions-md location | `doc/guardrails-suggestions-{TIMESTAMP}.md` by default. Timestamped so successive runs don't clobber each other; users can git-track or ignore as they prefer. |
| Near-match handling | Always *suggest* (never auto-apply) by default. Per-project policy set during `guardrails:init`: **fix** (auto-apply), **leave** (no output), or **notify** (suggest only). |

---

## Sample App (`examples/`)

A full Rails app maintained in-repo, serving three purposes:

1. **Integration test surface** — every audit type runs against it in CI; canonical fixture for "does Guardrails actually work end-to-end"
2. **Showcase** — visual material for the talk, blog posts, README screenshots
3. **Onboarding** — clone-and-run reference for users adopting the gem

Contents:
- Seeded "good" baseline (tokens, sprite, ViewComponents using them correctly)
- Seeded violations for each audit type (intentional drift to demo the report)
- Both ERB partials and ViewComponents in use
- Stimulus controllers (one orphaned, one dead, several healthy)
- Lookbook installed (V1) for ViewComponent integration demo

---

## Open Questions

1. **Near-match threshold**: When does a hex value count as "near-match" to a token? Pure ΔE color distance? Hamming distance on hex digits? Configurable threshold in `guardrails.yml`?
2. **`guardrails:init` rerunnability**: If a user reruns `init`, do we overwrite their config, merge, or refuse? Probably refuse-with-`--force`.
3. **Media query scaffold conflicts**: If the user already has a `prefers-color-scheme` block but it's empty/sparse, do we leave it alone, augment it, or comment our TODOs nearby? Probably leave-alone, comment in the suggestions artifact.
