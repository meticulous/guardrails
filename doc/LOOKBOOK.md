# Lookbook integration

Guardrails ships a per-component reporter that surfaces audit findings inside [Lookbook](https://lookbook.build) previews. The reporter returns a Hash; you render it however you like.

## What you get back

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

## Wiring a Lookbook panel

In an initializer (e.g. `config/initializers/lookbook.rb`):

```ruby
Rails.application.config.lookbook.preview_inspector.panels.add(:guardrails) do |panel|
  panel.label    = "Guardrails"
  panel.partial  = "lookbook_panels/guardrails"
  panel.locals   = lambda do |data|
    report = Guardrails::Lookbook::ComponentReport.new(root: Rails.root)
    { findings: report.for(data.preview.preview_class.name) }
  end
end
```

Then create `app/views/lookbook_panels/_guardrails.html.erb`:

```erb
<% if findings.nil? %>
  <p class="text-gray-500">No Guardrails data for this component.</p>
<% else %>
  <% if findings[:violations].any? %>
    <h4>Drift in template</h4>
    <ul>
      <% findings[:violations].each do |v| %>
        <li>
          <strong><%= v[:type] %></strong> <%= v[:file] %>:<%= v[:line] %> —
          <code><%= v[:snippet] %></code>
        </li>
      <% end %>
    </ul>
  <% end %>

  <% if findings[:orphan_slots].any? %>
    <h4>Orphan slots</h4>
    <ul>
      <% findings[:orphan_slots].each do |o| %>
        <li>:<%= o[:slot] %> (<%= o[:slot_kind] %>) declared but not rendered</li>
      <% end %>
    </ul>
  <% end %>

  <% if findings[:similar_templates].any? %>
    <h4>Similar components</h4>
    <ul>
      <% findings[:similar_templates].each do |s| %>
        <li><%= s[:partner] %> (<%= (s[:score] * 100).round %>% match)</li>
      <% end %>
    </ul>
  <% end %>

  <% if findings.values_at(:violations, :orphan_slots, :similar_templates).all?(&:empty?) %>
    <p class="text-green-600">No findings — this component is clean.</p>
  <% end %>
<% end %>
```

## Performance note

`ComponentReport#for` runs the full audit, view-component audit, and partial similarity pass on every call, then filters by component. For large codebases that's wasteful when Lookbook re-renders frequently. If you hit perf issues, cache results per Lookbook session or move audit invocation to a background job that writes JSON to disk for the panel to read.
