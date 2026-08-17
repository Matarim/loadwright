# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    # Binds a transport, a collector and a CapabilityTimeline into the single
    # object the load engine depends on. Everything downstream asks this for
    # capability; nothing downstream reads config.execution_mode.
    #
    # Specified in references/execution-modes.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class ExecutionContext
      def issue(*, **, &)
        raise NotImplementedError, "Loadwright::Execution::ExecutionContext#issue is not implemented yet"
      end

      def degrade!(*, **, &)
        raise NotImplementedError, "Loadwright::Execution::ExecutionContext#degrade! is not implemented yet"
      end
    end
  end
end
