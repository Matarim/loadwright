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

          # `as: :json` when there is a structured body, so both transports send the
          # same thing: :http already JSON-encodes and sets the content type, while
          # ActionDispatch would otherwise form-encode and turn every value into a
          # string. That difference is invisible for most REST params, which Rails
          # coerces anyway, and fatal for GraphQL -- `Int!` rejects "3".
          json = request.body.is_a?(Hash) || request.body.is_a?(Array)

          session.process(
            request.verb,
            request.full_path,
            **{ params: request.body, headers: rack_headers(request) },
            **(json ? { as: :json } : {})
          )

          response = session.response

          RawResponse.new(
            request: request,
            status: response.status,
            headers: response.headers,
            body: response.body,
            latency_ms: monotonic_ms - started_ms,
            app_exception: app_exception_from(session),
            transport: name
          )
        end

        # WE ARE IN THE SAME PROCESS AND WE ALREADY HAVE IT.
        #
        # Rails rescues most exceptions and renders an error page, so a 500 reaches us
        # as an ordinary status with a large HTML body and no way to tell what raised.
        # Reproducing that by hand is exactly the work a reader should not have to do:
        # in one real integration, fifteen endpoints failed identically for three
        # rounds and the cause was found only by tracing the application's source.
        #
        # CLASS AND ONE FRAME, NEVER THE MESSAGE. An exception message routinely
        # carries record ids, tokens and parameter values; the class and the frame that
        # raised are what identify the failure and neither is data.
        def app_exception_from(session)
          exception = session.request.env["action_dispatch.exception"]
          return nil unless exception.is_a?(Exception)

          {
            class: exception.class.name,
            frame: application_frame(exception),
            containment: containment_cause(exception)
          }.compact
        rescue StandardError
          # Diagnostics must never become the reason a measured request fails.
          nil
        end

        # The first frame outside the gems, which is the line in THEIR code that a
        # reader can open. A backtrace whose top frame is inside a gem names the
        # library, not the decision that called it.
        def application_frame(exception)
          frames = Array(exception.backtrace)
          frames.find { |frame| !frame.include?("/gems/") && !frame.start_with?(RbConfig::CONFIG["libdir"].to_s) } ||
            frames.first
        end

        # ONLY WE CAN SEE THIS ONE. When our own outbound-HTTP containment is what
        # broke the request, the application looks broken and is not -- and the user
        # has no way to tell the difference, because the block is ours. Observed for
        # real: a JWKS fetch refused by containment, rescued and re-raised by the app
        # as its own error class, reported as fourteen broken endpoints and
        # misattributed to seeding for three rounds.
        #
        # Walks `cause`, because the interesting case is precisely the one where the
        # app rescued our error and raised its own.
        def containment_cause(exception)
          seen = 0
          current = exception
          while current && seen < 10
            return "blocked by config.block_outbound_http: #{blocked_host(current)}" if
              current.class.name.to_s.include?("WebMock::NetConnectNotAllowedError")

            current = current.cause
            seen += 1
          end
          nil
        end

        # The host only. WebMock's message carries the full URI including any query
        # string, and a query string is the caller's data.
        def blocked_host(error)
          error.message.to_s[%r{https?://([^/\s"']+)}, 1] || "an external host"
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
