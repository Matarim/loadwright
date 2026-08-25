# frozen_string_literal: true

require "loadwright/execution/transport/base"

module Loadwright
  module Execution
    module Transport
      # Requests through ActionDispatch::Integration::Session, in the same process
      # as Loadwright. The full Rails middleware stack runs; the web server does
      # not. This is the default, because zero setup matters more than it sounds:
      # a tool that needs orchestration before the first result gets abandoned
      # during evaluation.
      #
      # What it CANNOT honestly measure is a property of the transport and is
      # recorded once, in CapabilityProfile.derive — not re-derived here. There is
      # no real thread pool, no request queueing, and no socket, so
      # latency-under-concurrency, pool exhaustion, and true client latency are
      # marked unavailable rather than reported as zero or "looks fine".
      #
      # One session per thread. ActionDispatch's session carries cookies and
      # last-response state, so sharing one across concurrent threads would
      # interleave two requests' state — and under allow_in_process_threading that
      # would show up as a wrong status code attributed to the wrong request.
      class InProcess < Base
        def initialize(config: Loadwright.configuration, dry_run: false, app: nil)
          super(config: config, dry_run: dry_run)
          @app = app
          @sessions = {}
          @mutex = Mutex.new
        end

        def name = :in_process

        def ready? = !application.nil?

        # ActionDispatch::Integration defaults this to "www.example.com", which Rails'
        # HostAuthorization middleware BLOCKS: its development allow-list is
        # localhost, 127.0.0.1, ::1, .localhost and .test. Every request would be
        # answered 403 by the middleware without ever reaching the app, and the run
        # would report every endpoint `inconclusive` -- with the run-level diagnosis
        # blaming auth_token_provider, which is exactly the confidently-wrong answer
        # this tool exists to avoid.
        #
        # "localhost" is what a developer hitting their own app types, and it is on
        # that allow-list. An app with its own allowed hosts can still override it
        # through config.default_headers["Host"], which merges over this.
        DEFAULT_HOST = "localhost"

        def start!
          load_integration!
          raise ServerError, "no Rails application is available for :in_process execution" unless ready?

          self
        end

        private

        def perform(request, started_ms)
          session = session_for_current_thread

          session.process(
            request.verb,
            request.full_path,
            params: request.body,
            headers: rack_headers(request)
          )

          response = session.response

          RawResponse.new(
            request: request,
            status: response.status,
            headers: response.headers,
            body: response.body,
            latency_ms: monotonic_ms - started_ms,
            transport: name
          )
        end

        def application
          @app || (defined?(::Rails) && ::Rails.respond_to?(:application) ? ::Rails.application : nil)
        end

        def session_for_current_thread
          load_integration!

          @mutex.synchronize do
            @sessions[Thread.current.object_id] ||=
              ::ActionDispatch::Integration::Session.new(application).tap { |s| s.host = DEFAULT_HOST }
          end
        end

        # action_dispatch/testing/integration references
        # ActionController::TemplateAssertions at load time, so action_controller
        # has to be required first. Autoloading Session lazily gets this wrong and
        # surfaces as a NameError trapped into a nil-status RawResponse — i.e. as a
        # mysteriously failing endpoint rather than a setup problem.
        def load_integration!
          return if @integration_loaded

          require "action_controller"
          require "action_dispatch"
          require "action_dispatch/testing/integration"
          @integration_loaded = true
        end

        # ActionDispatch wants Rack-style env keys for anything that is not a
        # standard header, but accepts plain header names in `headers:` and
        # converts them. The correlation id goes through as a header so the
        # collector middleware reads it identically in both transports — which is
        # what keeps the two modes' correlation paths from diverging.
        def rack_headers(request)
          merged_headers(request).merge(CollectorMiddleware::REQUEST_ID_HEADER => request.request_id)
        end
      end
    end
  end
end
