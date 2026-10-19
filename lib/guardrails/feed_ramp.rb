# frozen_string_literal: true

require_relative "feed_ramp/manifest"
require_relative "feed_ramp/agent_rules"

module Guardrails
  # Feed Ramp: the before-the-fact half of Guardrails. Gives coding agents
  # the app's real component library and design tokens, so they render
  # what exists instead of reinventing it, where the audit can only flag
  # the drift afterwards.
  #
  #   - Manifest: `.ui_guardrails/manifest.json` and `COMPONENTS.md`,
  #     built statically from the app's ViewComponent and Phlex
  #     components, Lookbook previews, call sites and tokens.
  #   - AgentRules: a block in CLAUDE.md / AGENTS.md and a Cursor rule
  #     that point agents at the manifest.
  module FeedRamp
  end
end
