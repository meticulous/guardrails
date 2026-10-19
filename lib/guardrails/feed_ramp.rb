# frozen_string_literal: true

require_relative "feed_ramp/manifest"
require_relative "feed_ramp/agent_rules"
require_relative "feed_ramp/score"

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
  #   - Score: a UI drift number for before/after comparisons.
  #   - MCP (`feed_ramp/mcp`, loaded on its own): the manifest as tools
  #     for coding agents, run by `ui_guardrails-mcp`.
  module FeedRamp
  end
end
