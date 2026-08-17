# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # db / view / GC / external / other, from process_action.action_controller.
    # Must disclose containment skew: suppressed jobs and blocked outbound HTTP make
    # the app faster than production reality.
    #
    # Specified in references/performance-signals.md (Part 1)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class TimeBreakdown
      def breakdown(*, **, &)
        raise NotImplementedError, "Loadwright::Analysis::TimeBreakdown#breakdown is not implemented yet"
      end
    end
  end
end
