// Stimulus Application instance for the demo. Kept tiny — the seeded
// controllers in this directory exist so Guardrails' stimulus_audit
// has something to talk about, not to function at runtime.
import { Application } from "@hotwired/stimulus"

const application = Application.start()
application.debug = false
window.Stimulus = application

export { application }
