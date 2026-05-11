// Eager-load every `*_controller.js` under this directory and register
// it with the shared Stimulus Application. Stimulus' file-name →
// controller-identifier convention turns `toggle_controller.js` into
// `data-controller="toggle"` (matching what Guardrails' stimulus_audit
// expects when it cross-references definitions against view usage).
import { application } from "./application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

eagerLoadControllersFrom("controllers", application)
