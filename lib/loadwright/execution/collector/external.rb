# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    module Collector
      # No middleware reachable (remote target that does not load the gem). Yields
      # status, latency and payload size only, and reports every query-derived signal
      # as unavailable rather than as zero.
      #
      # Specified in references/execution-modes.md
      #
      # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
      class External
        def collect(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Collector::External#collect is not implemented yet"
        end

        def capabilities(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Collector::External#capabilities is not implemented yet"
        end
      end
    end
  end
end
