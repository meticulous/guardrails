# Guardrails demo app

A bootable Rails 7.2 application with intentionally seeded UI drift so every Guardrails audit produces visible findings. Used as the talk demo, the gem's integration-test surface, and a clone-and-run reference for new users.

## Boot

```bash
cd examples/demo
bin/setup            # bundle install + summary
bin/rails server     # http://localhost:3000
```

Then open:

| URL | What it shows |
|---|---|
| `/` | Clean baseline page — no findings. |
| `/broken` | Every detector trips on this page. |
| `/rails/lookbook` | Lookbook previews with the Guardrails panel auto-attached to every preview. |

## Run the audits

From the demo root:

```bash
bundle exec rake guardrails:audit          # full report
bundle exec rake guardrails:icons          # icon sprite + dead-icon scan
bundle exec rake guardrails:tokens         # token drift in stylesheets
bundle exec rake guardrails:audit FORMAT=json   # machine-readable
SUGGEST=1 bundle exec rake guardrails:audit     # write doc/guardrails-suggestions-{ts}.md
APPLY=1   bundle exec rake guardrails:audit     # auto-fix raw_color + tailwind_arbitrary where a token matches
AXE_JSON=axe.json bundle exec rake guardrails:audit  # fold deep a11y findings in
```

`guardrails:init` refuses to overwrite the existing `guardrails.yml` — by design. Use `FORCE=1 bundle exec rake guardrails:init` to re-scaffold.

## Layout

```
examples/demo/
├── Gemfile                                rails 7.2, view_component, lookbook, guardrails (path: ../..)
├── config/                                minimal Rails skeleton (no AR/AC/AM/AJ)
├── bin/                                   rails + setup
├── guardrails.yml                         config the gem reads
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb
│   │   └── welcome_controller.rb          / and /broken
│   ├── views/
│   │   ├── layouts/application.html.erb
│   │   ├── welcome/
│   │   │   ├── index.html.erb             clean baseline
│   │   │   └── broken.html.erb            seeded violations (every detector)
│   │   └── shared/
│   │       ├── _hero_card.html.erb        similar to ↓
│   │       └── _hero_card_alt.html.erb    similar partial
│   ├── components/
│   │   ├── button_component.rb            clean: has preview, slot rendered
│   │   ├── card_component.rb              broken: no preview, orphan slot
│   │   └── icon_button_component.rb       structurally similar to button
│   ├── javascript/
│   │   ├── application.js                 stimulus boot
│   │   └── controllers/
│   │       ├── toggle_controller.js       healthy
│   │       └── dead_controller.js         dead — no view uses it
│   └── assets/
│       ├── images/icons/                  source SVGs (one is dead)
│       └── stylesheets/
│           ├── tokens/_colors.css         CSS custom property tokens
│           └── application.scss           clean usage + seeded drift
└── test/components/previews/
    └── button_component_preview.rb        preview for button (only one)
```

## Expected findings

| Audit | Expected |
|---|---|
| `audit` view scan | inline_style, raw_color (×2 matching tokens, ×1 no match), tailwind_arbitrary, helper_recommended (on `<button><%= variant %>`) |
| `audit` stimulus | 1 orphaned (`data-controller="missing"`), 1 dead (`dead_controller.js`) |
| `audit` partial similarity | `_hero_card.html.erb` ↔ `_hero_card_alt.html.erb`, plus button vs icon_button components |
| `audit` view components | `card_component` missing preview, `card_component` orphan slot |
| `audit` a11y | image_alt, button_name, link_name in `welcome/broken.html.erb` |
| `audit` cross-codebase patterns | small repo → no patterns at default thresholds (expected) |
| `audit` class-itis | small repo → no clusters at default thresholds (expected) |
| `icons` sprite | generates `app/assets/images/icons/sprite.svg` |
| `icons` inline SVGs | flags one inline `<svg><path/></svg>` in `welcome/broken.html.erb` |
| `icons` dead icons | `search.svg` (no view references `#icon-search`) |
| `tokens` drift | hex literals in `application.scss` matched/unmatched against defined tokens |
