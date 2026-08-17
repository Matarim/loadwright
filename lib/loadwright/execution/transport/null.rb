# frozen_string_literal: true

require "loadwright/execution/transport/base"

module Loadwright
  module Execution
    module Transport
      # Scripted responses, no Rails and no socket. Backs two things:
      #
      # 1. --dry-run, where issuing anything is a violation rather than a no-op.
      # 2. The gem's own fast tests, which is why the entire downstream pipeline —
      #    analysis, correlation, the engine's matrix construction, the resource
      #    guard's ladder — can be exercised without booting anything.
      #
      # Built FIRST, before the real transports, deliberately: with this in place
      # there is no temptation to test the analysis pipeline through Puma, which
      # is slow enough that the tests would get written thinly or not at all.
      #
      # And the standing counterweight, because this convenience is exactly how a
      # suite drifts: execution-modes.md requires at least one real end-to-end run
      # per transport against examples/sample_app. Fast test doubles drift from
      # reality precisely because they are convenient.
      class Null < Base
        # A scripted response. `body` may be a String or anything that responds to
        # #to_json-able structure; it is serialised at construction so the
        # transport hands back exactly what a real one would.
        Script = Struct.new(:status, :headers, :body, :latency_ms, :error, keyword_init: true)

        attr_reader :issued

        # `responder` may be:
        #   * a Hash keyed by "VERB /path" or by endpoint_key
        #   * a callable taking the Request and returning a Script or Hash
        #   * nil, meaning a bare 200 with an empty JSON array
        def initialize(config: Loadwright.configuration, dry_run: false, responder: nil)
          super(config: config, dry_run: dry_run)
          @responder = responder
          @issued = []
        end

        def name = :null

        # Every request this transport was asked for. Used by the dry-run spec to
        # assert on the adapter directly rather than on printed output — output
        # text is not evidence that nothing was sent.
        def issued_count = @issued.length

        private

        def perform(request, started_ms)
          @issued << request
          script = resolve(request)

          raise script.error if script.error

          RawResponse.new(
            request: request,
            status: script.status,
            headers: script.headers,
            body: script.body,
            # A scripted latency when given, so statistics and the resource
            # guard's Tier 3 degradation check are testable; otherwise real
            # elapsed time, which is near zero.
            latency_ms: script.latency_ms || (monotonic_ms - started_ms),
            transport: name
          )
        end

        def resolve(request)
          scripted =
            case @responder
            when nil then nil
            when Proc then @responder.call(request)
            when Hash then @responder[request.endpoint_key] || @responder["#{request.verb.to_s.upcase} #{request.path}"]
            else @responder.call(request)
            end

          case scripted
          when Script then scripted
          when Hash then Script.new(**default_script.to_h.merge(scripted))
          when nil then default_script
          else raise ArgumentError, "unusable Null transport script: #{scripted.inspect}"
          end
        end

        def default_script
          Script.new(status: 200, headers: { "content-type" => "application/json" }, body: "[]")
        end
      end
    end
  end
end
