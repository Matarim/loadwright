# frozen_string_literal: true

# A deliberately small, deliberately flawed Rails API.
#
# Every analysis path Loadwright has needs a LIVE fixture rather than a mock,
# because a mock of a query pattern is a mock of the thing under test. So this app
# contains, on purpose:
#
#   * an unpaginated collection with an N+1                (posts#index)
#   * a PAGINATED collection with an N+1                   (authors#index)
#   * an endpoint that over-fetches                        (tags#index)
#   * an endpoint that always 403s                         (admin/stats#show)
#   * a clean, correctly-preloaded nested collection       (comments#index)
#   * a factory missing a sequence on a unique column      (spec/factories.rb)
#
# authors#index is the important one. It is the regression fixture for
# response-analysis.md Part 2: because it paginates, its query count stays flat as
# seeded rows grow, so the SEEDED-scale slope reports it as perfectly healthy. Only
# the returned-record-count slope — swept via per_page — sees the N+1.
#
# This is not an example of good Rails. It is a test fixture whose bugs are load
# bearing. Do not "fix" them.

require "logger"

# active_record/railtie, not just active_record. The railtie is what mixes
# ActiveRecord::Railties::ControllerRuntime into ActionController, and that is what
# puts `db_runtime` on the process_action payload — which is where Loadwright's time
# breakdown reads it from. Requiring only `active_record` gives working models and a
# permanently nil db_runtime, so the fixture would exercise the degraded path while
# looking like a normal app.
require "active_record/railtie"
require "action_controller/railtie"

# A host app loads the gem through Bundler.require from its :development, :test
# group. This fixture has no Gemfile of its own, so it requires it directly — and it
# must, because the railtie is what mounts the identity endpoint. Without it, the
# :http health probe 404s and Loadwright waits out the whole http_boot_timeout before
# reporting a boot failure. (That is exactly how this was found.)
require "loadwright"

module SampleApp
  class Application < ::Rails::Application
    config.load_defaults 7.0 if config.respond_to?(:load_defaults)

    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.api_only = true
    config.consider_all_requests_local = true
    config.hosts.clear if config.respond_to?(:hosts)
    config.secret_key_base = "loadwright-sample-app-not-a-secret"

    # Quiet, but not silent: a boot failure has to be visible, since it is the
    # most common reason an :http run never becomes healthy.
    config.logger = Logger.new($stderr, level: Logger::WARN)
    config.log_level = :warn

    config.autoload_paths += Dir[File.expand_path("../app/*", __dir__)]
    config.eager_load_paths += Dir[File.expand_path("../app/*", __dir__)]

    # So a spec can assert Loadwright honours the host app's own filter list
    # rather than only its built-in patterns.
    config.filter_parameters += [:password, :internal_ref]

    config.middleware.delete ActionDispatch::HostAuthorization if defined?(ActionDispatch::HostAuthorization)
  end
end
