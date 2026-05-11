# frozen_string_literal: true

# Single-threaded, single-worker — minimal footprint for a demo.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 1)
threads threads_count, threads_count
port ENV.fetch("PORT", 3000)
environment ENV.fetch("RAILS_ENV", "development")
