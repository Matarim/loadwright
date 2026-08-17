# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Instrumentation
    # Allocation counts and GC deltas per request.
    #
    # Specified in references/performance-signals.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class MemoryTracker
      def start!(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::MemoryTracker#start! is not implemented yet"
      end

      def stop!(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::MemoryTracker#stop! is not implemented yet"
      end

      def metrics(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::MemoryTracker#metrics is not implemented yet"
      end
    end
  end
end
