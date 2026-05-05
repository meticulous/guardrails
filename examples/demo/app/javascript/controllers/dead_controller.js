// Seeded dead: no view declares data-controller="dead".
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    console.log("you'll never see this — guardrails:audit will flag the file")
  }
}
