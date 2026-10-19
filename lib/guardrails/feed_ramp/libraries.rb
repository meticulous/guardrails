# frozen_string_literal: true

require "pathname"

module Guardrails
  module FeedRamp
    # Which component libraries the app has, from Gemfile.lock: the
    # version for each one it locks, nil for the rest. Read from the
    # lockfile rather than `defined?(::ViewComponent)` so it works
    # without booting the app (sidecar installs, agent tools).
    module Libraries
      GEMS = %w[lookbook phlex phlex-rails view_component].freeze

      # Top-level specs in the lockfile's GEM section are indented four
      # spaces; their own dependencies, six.
      SPEC_LINE = /^ {4}(#{GEMS.map { |g| Regexp.escape(g) }.join("|")}) \(([^)]+)\)$/

      module_function

      def detect(root)
        lockfile = Pathname(root).join("Gemfile.lock")
        found = lockfile.file? ? lockfile.read.scan(SPEC_LINE).to_h : {}
        GEMS.to_h { |name| [name, found[name]] }
      end
    end
  end
end
