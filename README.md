# Guardrails

> **⚠️ Under Development** — This gem is not yet ready for use. Watch this repo for updates.

Guardrails is a Rails toolset for preventing UI drift in AI-assisted applications. It provides opinionated auditing and enforcement tasks for design system consistency — component inventory, icon sprites, type scale, and color token management.

Built and maintained by [Meticulous](https://meticulous.com).

---

## The Problem

AI-assisted Rails development is fast. Too fast. Without design guardrails in place, codebases accumulate inconsistent spacing, ad-hoc color values, duplicate components, and icon sprawl. The UI drifts. The design system erodes.

Guardrails gives Rails developers without dedicated designers a set of enforceable constraints to keep UI consistent as they ship.

---

## Planned Features

- `rails guardrails:audit` — component inventory and inconsistency detection
- `rails guardrails:icons` — SVG sprite generation and audit
- `rails guardrails:tokens` — type scale and color variable extraction and enforcement
- `guardrails.yml` — project-level configuration for your design constraints

---

## Status

Early development. Not ready for production use.

Follow along: [meticulous.com](https://meticulous.com)

---

## License

MIT
