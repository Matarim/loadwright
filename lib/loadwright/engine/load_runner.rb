# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Engine
    # The matrix runner.
    #
    # TWO SEPARATE SWEEPS, never one combined matrix — varying both axes at once
    # makes the slope unattributable:
    #   * seed-scale sweep, page size FIXED  -> does query COST grow with table size?
    #   * page-size sweep, seed scale FIXED  -> does query COUNT grow with records
    #                                           returned? (this is the N+1)
    #
    # Baseline latency per endpoint is measured at concurrency 1 before any ramp,
    # because the resource guard's Tier 3 check needs it. That ordering is a hard
    # dependency. Every cell records the concurrency it ACTUALLY ran at.
    #
    # Specified in references/discovery-and-load-engine.md (Part 3)
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class LoadRunner
      def run!(*, **, &)
        raise NotImplementedError, "Loadwright::Engine::LoadRunner#run! is not implemented yet"
      end
    end
  end
end
