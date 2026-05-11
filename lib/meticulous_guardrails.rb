# frozen_string_literal: true

# Shim so that `gem "meticulous_guardrails"` in a Gemfile and the
# default Bundler/Rails auto-require pattern (`require "meticulous_
# guardrails"`) reach the canonical entry point at lib/guardrails.rb.
# The Ruby module is `Guardrails`; only the gem package name on
# rubygems.org is namespaced under the org. See the CHANGELOG entry
# for 1.0.0 for the rename rationale.
require_relative "guardrails"
