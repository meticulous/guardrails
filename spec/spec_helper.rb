# frozen_string_literal: true

require "guardrails"

module GitHelper
  # For specs that commit to a repo in a temp dir. Without the
  # maintenance settings, a commit can start git's background
  # maintenance, which writes .git/objects/maintenance.lock while
  # Dir.mktmpdir is deleting the repo, and the cleanup fails with ENOENT.
  QUIET_CONFIG = ["-c", "user.email=t@example.com", "-c", "user.name=T", "-c", "maintenance.auto=false",
                  "-c", "gc.auto=0", "-c", "commit.gpgsign=false"].freeze
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end
