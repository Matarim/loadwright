# frozen_string_literal: true

require "loadwright/execution/collector/base"

module Loadwright
  module Execution
    module Collector
      # Nothing app-side. The collector for a remote target that does not load the
      # gem, or one where the middleware could not be installed.
      #
      # Its whole job is to be honest about what it does not know. Every
      # query-derived field is Measurement.unavailable with a reason a developer
      # can act on, and there is no path here that produces a 0. That matters more
      # than it sounds: zero queries is the single most dangerous wrong number this
      # tool could print, because it reads as a perfectly optimised endpoint. An
      # endpoint that "has no N+1" because nobody was watching is not the same as
      # one that has no N+1.
      #
      # What survives, and keeps working, is everything response-derived: status,
      # latency, payload size, record counts, schema validity. response-analysis.md
      # requires reporting that available subset rather than dropping the endpoint
      # entirely — a degraded run is still useful, as long as it announces its
      # degradation.
      class External < Base
        REASON = "no collector middleware; query data cannot be retrieved from the target"

        def collector_name = :external

        def collect(request, raw_response, capability_epoch: 0)
          unavailable_metrics(
            request,
            REASON,
            capability_epoch: capability_epoch,
            except: response_derived(raw_response, request)
          )
        end
      end
    end
  end
end
