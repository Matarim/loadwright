# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Instrumentation
    # Pool busy/waiting/size high-water marks.
    #
    # Specified in references/performance-signals.md (Part 4)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class ConnectionPoolTracker
      def start!(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::ConnectionPoolTracker#start! is not implemented yet"
      end

      def stop!(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::ConnectionPoolTracker#stop! is not implemented yet"
      end

      def metrics(*, **, &)
        raise NotImplementedError, "Loadwright::Instrumentation::ConnectionPoolTracker#metrics is not implemented yet"
      end
    end
  end
end
