# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Engine
    # Samples database health on a connection held OUTSIDE the pool under test —
    # polling through a saturated pool means the health check fails first and
    # visibility is lost exactly when it is needed.
    #
    # Specified in references/resource-contention.md (Tier 2)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class HealthPoller
      def start!(*, **, &)
        raise NotImplementedError, "Loadwright::Engine::HealthPoller#start! is not implemented yet"
      end

      def stop!(*, **, &)
        raise NotImplementedError, "Loadwright::Engine::HealthPoller#stop! is not implemented yet"
      end

      def sample(*, **, &)
        raise NotImplementedError, "Loadwright::Engine::HealthPoller#sample is not implemented yet"
      end
    end
  end
end
