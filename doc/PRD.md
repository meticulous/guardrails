# Guardrails — Product Requirements Document

**Status:** Draft  
**Owner:** John Athayde / Meticulous  
**Last updated:** 2026-05-04

---

## Problem Statement

AI-assisted Rails development accelerates shipping but introduces a new failure mode: UI drift. Developers using Copilot, Claude, or similar tools generate UI code fast — too fast to maintain design system consistency. The result is:

- Duplicate or near-duplicate components
- Ad-hoc color values that bypass design tokens
- Icon sprawl (inline SVGs, mixed icon sets, no sprite optimization)
- Type scale violations (hardcoded font sizes, inconsistent heading hierarchy)
- No enforcement layer between "AI wrote this" and "this ships"

Rails developers without dedicated designers have no tooling to catch this before it compounds.

---

## Target User

**Primary:** Rails developers at small-to-mid-sized product companies who:
- Ship UI features frequently (weekly or faster)
- Use AI coding assistants
- Don't have a dedicated designer or design system engineer
- Care about consistency but lack the time to enforce it manually

**Secondary:** Design-aware Rails consultants (Meticulous ICP) who want to hand clients something they can run themselves post-engagement.

---

## Goals

1. Give Rails devs a single command to audit UI consistency across a codebase
2. Enforce design token usage (colors, type scale) via configurable rules
3. Generate optimized icon sprites from raw SVG assets
4. Integrate naturally into existing Rails workflows (rake tasks, CI)
5. Be opinionated but configurable

---

## Non-Goals

- Not a design system generator (doesn't create components for you)
- Not a linter replacement (Rubocop, ESLint still own their domains)
- Not a visual regression tool (no screenshots/diffs)
- Not a component library

---

## Features

### 1. Component Audit (`rails guardrails:audit`)

Scans views and partials for:
- Near-duplicate partials (structural similarity, not just naming)
- Inline styles that bypass CSS custom properties
- Hardcoded color values (hex, rgb) outside of token files
- Hardcoded font-size/line-height values outside of type scale

Outputs: summary report to stdout + optional JSON/HTML report

### 2. Icon Management (`rails guardrails:icons`)

- Scans configured SVG source directory
- Generates optimized SVG sprite sheet
- Audits for inline SVGs in views that should be sprite references
- Reports icon usage frequency (find dead icons)

### 3. Design Token Enforcement (`rails guardrails:tokens`)

- Reads a `guardrails.yml` token definition (colors, type scale, spacing)
- Scans CSS/SCSS/Tailwind config for values that don't match defined tokens
- Reports violations with file + line number
- Optional: auto-suggest the closest token for a given raw value

### 4. Configuration (`guardrails.yml`)

```yaml
guardrails:
  icons:
    source: app/assets/images/icons
    sprite_output: app/assets/images/icons/sprite.svg

  tokens:
    colors_file: app/assets/stylesheets/tokens/_colors.scss
    type_scale_file: app/assets/stylesheets/tokens/_type.scss

  audit:
    scan_paths:
      - app/views
      - app/components
    ignore:
      - app/views/layouts
```

### 5. CI Integration

- Exit codes: 0 = clean, 1 = violations found
- `--strict` flag to fail CI on any violation
- `--format json` for machine-readable output

---

## Technical Approach

- Ruby gem, distributed via RubyGems
- Rake tasks registered via Railtie
- No runtime dependency — development/test group only
- Minimal dependencies (avoid pulling in heavy gems)

---

## Success Metrics

- Developers can run `rails guardrails:audit` in < 30 seconds on a mid-sized app
- Catches at least 80% of common UI drift patterns in a test app
- Zero false positives on a clean, well-structured Rails app
- Used by at least 3 Meticulous clients within 6 months of launch

---

## Open Questions

- [ ] Tailwind support: scan for arbitrary values in class strings? (complex but high value)
- [ ] ViewComponent vs ERB partials: audit strategy differs
- [ ] Auto-fix mode: is this in scope for v1?
- [ ] VS Code extension as a companion? (out of scope for now)
- [ ] Where do Stimulus controllers fit in the audit?

---

## Milestones

| Milestone | Target | Notes |
|-----------|--------|-------|
| PRD + README stub | 2026-05-04 | ✅ Done |
| Gem skeleton + Railtie | TBD | First Claude Code session |
| `guardrails:audit` v0 | TBD | |
| `guardrails:icons` v0 | TBD | |
| `guardrails:tokens` v0 | TBD | |
| Public beta / RubyGems publish | TBD | Before next speaking slot |
