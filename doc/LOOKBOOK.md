# Lookbook integration

When you have both Guardrails and [Lookbook](https://lookbook.build) in your Gemfile, Guardrails auto-registers a `:guardrails` panel that appears next to every preview, surfacing per-component audit findings inline. No initializer wiring required.

## What you see

In a preview's inspector, alongside the standard Source / Notes / Params panels, a **Guardrails** tab shows:

- **Drift in template** — `inline_style`, `raw_color`, `tailwind_arbitrary`, `helper_recommended` findings for the component's `.html.erb`
- **Orphan slots** — `renders_one` / `renders_many` declarations not rendered by the template
- **Similar templates** — other partials / components above the similarity threshold

If the component has no findings, the panel renders a "No findings — this component is clean." message. If Guardrails can't locate the component's class file under `app/components/`, the panel says so.

## How auto-registration works

The Railtie's `guardrails.lookbook_panel` initializer runs at app boot and is a no-op unless `defined?(::Lookbook)`. When Lookbook is present:

1. The gem prepends its view directory (`lib/guardrails/lookbook/views`) to `ActionController::Base.view_paths`, so the partial resolves.
2. It calls `Rails.application.config.lookbook.preview_inspector.panels.add(:guardrails)` with a locals lambda that, per render, runs `Guardrails::Lookbook::ComponentReport` against the current preview's component class.

## Programmatic access

The same data the panel renders is exposed as a plain Hash, useful for CI dashboards or custom rendering:

```ruby
Guardrails::Lookbook::ComponentReport.new(root: Rails.root).for("ButtonComponent")
# => {
#   component: "ButtonComponent",
#   class_file: "app/components/button_component.rb",
#   template_file: "app/components/button_component.html.erb",
#   violations: [
#     { type: :raw_color, file: "...", line: 3, column: 12, snippet: "...", value: "#0066ff" }
#   ],
#   orphan_slots: [
#     { component: "button", slot: "icon", slot_kind: :renders_one, file: "...", line: 4 }
#   ],
#   similar_templates: [
#     { partner: "app/components/icon_button_component.html.erb", score: 0.92 }
#   ]
# }
```

Returns `nil` when the component class file can't be located.

## Overriding the partial

The shipped partial deliberately uses class hooks (`lookbook-guardrails-empty`, `lookbook-guardrails-clean`) but no styling — the host app's design system wins. If you need a different layout entirely, drop a file at `app/views/lookbook_panels/_guardrails.html.erb` in your app: standard Rails view-path precedence puts the host's version ahead of the gem's.

## Performance note

`ComponentReport#for` runs the full audit, view-component audit, and partial-similarity pass on every panel render, then filters by component. For large codebases that's wasteful when Lookbook re-renders frequently. If you hit perf issues, cache results per Lookbook session or move audit invocation to a background job that writes JSON to disk for the panel to read.
