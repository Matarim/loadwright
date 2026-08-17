# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Execution
    module Collector
      # How per-request metrics come back. Returns Measurements, never nil, so an
      # unmeasured quantity cannot be rendered as zero.
      #
      # Specified in references/execution-modes.md
      #
      # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
      class Base
        def collect(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Collector::Base#collect is not implemented yet"
        end

        def capabilities(*, **, &)
          raise NotImplementedError, "Loadwright::Execution::Collector::Base#capabilities is not implemented yet"
        end
      end
    end
  end
end
