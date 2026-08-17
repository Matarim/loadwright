# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    module Collector
      # Correlates by X-Loadwright-Request-Id: cheap summaries on response headers,
      # detail from the guarded collection endpoint.
      #
      # IMPLEMENTATION NOTE: subscribe to sql.active_record ONCE at run start and
      # route events by a fiber-local request id (ActiveSupport::IsolatedExecutionState,
      # which honours the host's configured isolation_level). Subscribing per request
      # inside the middleware is the obvious implementation and is wrong — AS::N
      # subscribers are process-global, so under concurrency one request's subscriber
      # receives every other request's SQL.
      #
      # Specified in references/execution-modes.md
      #
      # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
      class Middleware
        def collect(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Collector::Middleware#collect is not implemented yet"
        end

        def capabilities(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Collector::Middleware#capabilities is not implemented yet"
        end
      end
    end
  end
end
