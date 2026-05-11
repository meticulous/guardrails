# frozen_string_literal: true

# Stimulus controllers under app/javascript/controllers are pinned for
# the demo. The two seeded controllers (`toggle`, `dead`) exist to give
# Guardrails' stimulus_audit something to talk about, not to function
# at runtime — we don't actually click anything.
pin "application", preload: true
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
