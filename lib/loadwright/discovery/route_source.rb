# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Discovery
    # Rails route introspection, filling gaps the other two sources leave. Lower
    # fidelity: no example params, so these are reported as 'discovered but no
    # example available; skipped' rather than guessed at.
    #
    # Specified in references/discovery-and-load-engine.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class RouteSource
      def endpoints(*, **, &)
        raise NotImplementedError, "Loadwright::Discovery::RouteSource#endpoints is not implemented yet"
      end
    end
  end
end
