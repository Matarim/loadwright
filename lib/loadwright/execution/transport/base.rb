# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/execution/raw_response"

module Loadwright
  module Execution
    module Transport
      # HOW A REQUEST IS ISSUED. One of the three seams.
      #
      # A transport knows nothing about instrumentation. That is not a style
      # preference — it is what stops capability being keyed off the transport.
      # An :http run against a remote target that does not load the gem uses the
      # SAME transport as a fully-instrumented one and has dramatically less
      # capability, so anything that derived "unavailable" from the transport
      # would be wrong in exactly the degraded-remote case, where a confidently
      # wrong number does the most damage.
      #
      # Subclasses implement #perform and return a RawResponse. Timing, error
      # trapping, and dry-run refusal are handled here so no transport can
      # accidentally omit them.
      class Base
        # Raised when a transport is asked to issue a request during a dry run.
        # A hard error rather than a no-op: Layer 4's guarantee is that a dry run
        # sends ZERO requests, and a silently-skipped request would make that
        # guarantee untestable from the outside.
        class DryRunViolation < Error; end

        attr_reader :config, :dry_run

        def initialize(config: Loadwright.configuration, dry_run: false)
          @config = config
          @dry_run = dry_run
        end

        def name = raise NotImplementedError, "#{self.class}#name"

        # Lifecycle hooks. Only :http needs them; the others are no-ops so the
        # engine never branches on transport type.
        def start! = self

        def stop! = self

        def ready? = true

        def issue(request)
          if dry_run
            raise DryRunViolation,
                  "transport #{name} was asked to issue #{request} during a dry run; " \
                  "a dry run must send zero requests"
          end

          started = monotonic_ms
          begin
            perform(request, started)
          rescue StandardError => e
            RawResponse.new(
              request: request, status: nil, headers: {}, body: nil,
              latency_ms: monotonic_ms - started, error: e, transport: name
            )
          end
        end

        private

        # Returns a RawResponse. `started_ms` is passed in so latency covers the
        # whole issue, including anything a subclass does before the wire call.
        def perform(_request, _started_ms)
          raise NotImplementedError, "#{self.class}#perform"
        end

        def monotonic_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)

        def merged_headers(request)
          config.default_headers.merge(request.headers)
        end
      end
    end
  end
end
