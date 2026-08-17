# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    # Rack middleware installed into the app under test. Mounted only while a
    # guard-approved run is active, bound to localhost, requires the per-run shared
    # secret, and refuses to mount at all in a production-flagged environment.
    #
    # Specified in references/execution-modes.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class CollectorMiddleware
      def call(*, **, &)
        raise NotImplementedError, "Loadwright::Execution::CollectorMiddleware#call is not implemented yet"
      end
    end
  end
end
