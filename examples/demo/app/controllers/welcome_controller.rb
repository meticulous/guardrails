# frozen_string_literal: true

class WelcomeController < ApplicationController
  # `/` — clean baseline page. No findings expected.
  def index; end

  # `/broken` — page with every seeded violation. Useful for the
  # "what Guardrails catches" side-by-side at the talk.
  def broken; end
end
