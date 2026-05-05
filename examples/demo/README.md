# Guardrails demo app

A minimal Rails-shaped directory tree with intentionally seeded UI drift so each Guardrails audit produces visible findings. Used as the talk demo, the gem's integration-test surface, and a clone-and-run reference for new users.

## Layout

```
examples/demo/
├── guardrails.yml                       config the gem reads
├── app/
│   ├── assets/
│   │   ├── images/icons/                source SVGs (one is dead)
│   │   └── stylesheets/
│   │       ├── tokens/_colors.css       CSS custom property tokens
│   │       └── application.scss         clean usage + seeded drift
│   ├── components/
│   │   ├── button_component.rb          clean: has preview, slot rendered
│   │   ├── card_component.rb            broken: no preview, orphan slot
│   │   └── icon_button_component.rb     structurally similar to button
│   ├── javascript/controllers/
│   │   ├── toggle_controller.js         healthy
│   │   └── dead_controller.js           dead — no view uses it
│   └── views/
│       ├── welcome/
│       │   ├── index.html.erb           clean baseline
│       │   └── broken.html.erb          seeded violations (every detector)
│       └── shared/
│           ├── _hero_card.html.erb      similar to ↓
│           └── _hero_card_alt.html.erb  similar partial
└── test/components/previews/
    └── button_component_preview.rb      preview for button (only one)
```

## Run the audits

From the gem repo root:

```bash
bundle exec rake -f lib/tasks/guardrails.rake guardrails:audit \
  -- $(pwd)/examples/demo

# or, to point Rails-style:
cd examples/demo
bundle exec --gemfile=../../Gemfile rake -f ../../lib/tasks/guardrails.rake guardrails:audit
```

Other tasks: `guardrails:icons`, `guardrails:tokens`, `guardrails:init` (init refuses to overwrite the existing config — by design).

## What gets reported

| Audit | Expected findings |
|---|---|
| `audit` view scan | inline_style, raw_color (×2 matching tokens, ×1 no match), tailwind_arbitrary |
| `audit` stimulus | 1 orphaned (`data-controller="missing"`), 1 dead (`dead_controller.js`) |
| `audit` partial similarity | `_hero_card.html.erb` ↔ `_hero_card_alt.html.erb`, plus button vs icon_button components |
| `audit` view components | `card_component` missing preview, `card_component` orphan slot |
| `audit` a11y | image_alt, button_name, link_name (in `welcome/broken.html.erb`) |
| `icons` sprite | generates `app/assets/images/icons/sprite.svg` |
| `icons` inline SVGs | flags one inline `<svg>...<path/>...</svg>` in `welcome/broken.html.erb` |
| `icons` dead icons | `search.svg` (no view references `#icon-search`) |
| `tokens` drift | hex literals in `application.scss` matched/unmatched to defined tokens |
