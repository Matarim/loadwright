# frozen_string_literal: true

require "loadwright/capability_profile"
require "loadwright/capability_timeline"
require "loadwright/errors"
require "loadwright/instrumentation/current_request"
require "loadwright/execution/collector/direct"
require "loadwright/execution/collector/external"
require "loadwright/execution/collector/middleware"
require "loadwright/execution/transport/http"
require "loadwright/execution/transport/in_process"
require "loadwright/execution/transport/null"

module Loadwright
  module Execution
    # Binds a transport, a collector, and a CapabilityTimeline into the single
    # object the load engine depends on. The engine asks this for a
    # (RawResponse, RequestMetrics) pair and never touches a transport or
    # collector directly.
    #
    # This is where the three seams meet, and where mid-run capability
    # degradation is turned into an epoch. That last part is the reason this class
    # exists at all rather than the engine holding a transport and a collector: a
    # collector that discovers it can no longer collect has to change the
    # capability record, and results collected before that point must keep their
    # original attribution. Somebody has to own that transition, and it is not the
    # engine's business.
    Outcome = Struct.new(:response, :metrics, :capability_epoch, keyword_init: true)

    class ExecutionContext
      attr_reader :transport, :collector, :capabilities, :server

      # Builds the pairing config asks for, and — importantly — decides the
      # COLLECTOR from what is actually reachable rather than from execution_mode.
      # An :http run against a target that will not answer the collection endpoint
      # gets External, and therefore honestly reduced capability, without any
      # other layer having to know.
      def self.build(config: Loadwright.configuration, dry_run: false, lifecycle: nil,
                     guard: nil, stdout: $stdout)
        return build_null(config: config, dry_run: dry_run) if dry_run

        case config.execution_mode
        when :in_process then build_in_process(config: config)
        when :http then build_http(config: config, lifecycle: lifecycle, guard: guard, stdout: stdout)
        else raise ConfigurationError, "unknown execution_mode #{config.execution_mode.inspect}"
        end
      end

      # --dry-run: a Null transport that raises if asked to issue anything, so the
      # "zero requests" guarantee is enforced by the object rather than by
      # everyone remembering to check a flag.
      def self.build_null(config:, dry_run: true, responder: nil)
        new(
          config: config,
          transport: Transport::Null.new(config: config, dry_run: dry_run, responder: responder),
          collector: Collector::External.new(config: config)
        )
      end

      def self.build_in_process(config:, app: nil, tracker: nil)
        new(
          config: config,
          transport: Transport::InProcess.new(config: config, app: app),
          collector: Collector::Direct.new(config: config, tracker: tracker)
        )
      end

      def self.build_http(config:, lifecycle: nil, guard: nil, stdout: $stdout)
        server = ServerManager.new(config: config, lifecycle: lifecycle, stdout: stdout)
        server.start!

        secret = mount_collector(config: config, guard: guard, stdout: stdout)

        collector =
          if secret
            Collector::Middleware.new(config: config, base_url: server.base_url, secret: secret)
          else
            # The degraded-remote case. Same transport, much less capability —
            # which is the entire reason capability is not keyed off the mode.
            Collector::External.new(config: config)
          end

        new(
          config: config,
          transport: Transport::Http.new(config: config, base_url: server.base_url, secret: secret),
          collector: collector,
          server: server
        )
      end

      # Mounting is only possible when the app under test is THIS process (or a
      # child that loads the gem). Against a remote target it is not, and the
      # honest answer is External rather than a middleware that silently measures
      # nothing.
      def self.mount_collector(config:, guard:, stdout:)
        return nil unless config.execution_mode == :http # capability-exempt: mount plumbing, not a capability decision
        return nil if !CollectorMiddleware.respond_to?(:mount!) || config.http_target_url

        tracker = Instrumentation::QueryTracker.new(config: config)
        tracker.start!
        CollectorMiddleware.mount!(tracker: tracker, guard: guard)
      rescue SafetyError => e
        # A refusal to mount is not a run-stopping error: the run continues with
        # reduced, honestly-labelled capability.
        stdout.puts "loadwright: #{e.message}"
        nil
      end

      def initialize(config:, transport:, collector:, server: nil, clock: nil)
        @config = config
        @transport = transport
        @collector = collector
        @server = server
        @capabilities = CapabilityTimeline.new(
          CapabilityProfile.derive(transport: transport.name, collector: collector.collector_name),
          **(clock ? { clock: clock } : {})
        )
      end

      def start!
        @transport.start!
        @collector.start_run!
        self
      end

      def stop!
        @collector.stop_run!
        @transport.stop!
        CollectorMiddleware.unmount! if CollectorMiddleware.mounted?
        @server&.stop!
        self
      end

      def capability_profile = @capabilities.current

      def capability_epoch = @capabilities.current_epoch

      # The one method the engine calls per request.
      #
      # The `ensure` is load bearing, not hygiene. begin_request marks this
      # execution context as belonging to a request id, and normally collect clears
      # it. If anything between the two raises — a collector bug, a middleware
      # timeout, an interrupt — the id stays set on this thread, and the NEXT
      # request's queries are attributed to the previous request. The endpoint that
      # errored gets credited with the following endpoint's N+1, which is a wrong
      # number rather than a missing one, and nothing downstream could detect it.
      def issue(request)
        @collector.begin_request(request)
        response = @transport.issue(request)

        # Read the epoch BEFORE folding in any degradation the collector reports,
        # so this request is attributed to the capability that was in effect while
        # it ran — not to the reduced one its own failure caused.
        epoch = @capabilities.current_epoch
        metrics = @collector.collect(request, response, capability_epoch: epoch)

        apply_degradation!

        Outcome.new(response: response, metrics: metrics, capability_epoch: epoch)
      ensure
        Instrumentation::CurrentRequest.clear!
      end

      def to_h
        {
          transport: @transport.name,
          collector: @collector.collector_name,
          dry_run: @transport.dry_run,
          server: @server&.to_h,
          capabilities: @capabilities.to_h
        }.compact
      end

      private

      # Turns a collector's reported degradation into a new epoch, once. The
      # collector records only the first degradation, and CapabilityTimeline is
      # idempotent for signals already at or below the requested status, so a
      # middleware failing on every request produces one epoch rather than one per
      # request.
      def apply_degradation!
        degradation = @collector.degradation
        return unless degradation
        return if @applied_degradations&.include?(degradation)

        (@applied_degradations ||= []) << degradation
        @capabilities.degrade!(degradation[:signals], reason: degradation[:reason])
      end
    end
  end
end
