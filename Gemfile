# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Development / test only. See the gemspec for why these are not runtime deps.
gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"

group :test do
  # Exercises the :http execution mode end-to-end against examples/sample_app.
  gem "puma", "~> 6.4"

  # examples/sample_app — the live fixture. Every analysis path needs a real
  # endpoint with a real N+1 against a real database, because a mock of a query
  # pattern is a mock of the thing under test. NOT runtime dependencies: the host
  # app supplies its own, and we deliberately use the host's factories.
  gem "activerecord", ">= 7.0"
  gem "factory_bot", "~> 6.4"
  gem "sqlite3", "~> 2.0"

  # So the fixture can exercise SIDE-EFFECT CONTAINMENT for real. Without them the
  # containment subsystem finds both measures unenforceable and aborts, so every
  # end-to-end run had to disable them -- meaning the contained path, which is the
  # DEFAULT path, was never exercised against a live app. They also make the job
  # fan-out finding reachable, since the :test adapter records instead of performing.
  gem "activejob", ">= 7.0"
  gem "actionmailer", ">= 7.0"

  # Required by config.block_outbound_http. Loadwright treats its absence as a
  # containment failure at runtime (see abort_if_containment_unavailable), so we
  # need it present here to test both the enforced and degraded paths.
  gem "webmock", "~> 3.23"
end
