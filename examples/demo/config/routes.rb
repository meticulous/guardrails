# frozen_string_literal: true

Rails.application.routes.draw do
  # Lookbook 2.x needs an explicit mount — pick `/rails/lookbook` so it
  # sits alongside Rails' own `/rails/...` dev tools. The Guardrails
  # panel is auto-registered by the gem's Railtie; no extra wiring.
  mount Lookbook::Engine, at: "/rails/lookbook" if defined?(Lookbook::Engine)

  root to: "welcome#index"
  get "/broken", to: "welcome#broken", as: :broken
end
