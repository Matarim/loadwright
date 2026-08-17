# frozen_string_literal: true

require "net/http"
require "uri"
require "loadwright/execution/transport/base"
require "loadwright/execution/collector_middleware"

module Loadwright
  module Execution
    module Transport
      # Genuine HTTP against a real server. Real threads, real request queueing,
      # real keepalive — which is the only way connection-pool findings and
      # latency-under-concurrency become real rather than fabricated.
      #
      # This transport does NOT boot the server; ServerManager does, and registers
      # its teardown with Lifecycle. Keeping them separate is what lets the same
      # transport point at a server Loadwright booted and at one that was already
      # running, which are the same wire behaviour and very different capability.
      #
      # One Net::HTTP connection per thread, kept alive. A shared connection under
      # concurrency would serialise the requests, which would make every
      # concurrency measurement a measurement of this transport instead of the app.
      class Http < Base
        attr_reader :base_uri

        def initialize(config: Loadwright.configuration, dry_run: false, base_url: nil, secret: nil)
          super(config: config, dry_run: dry_run)
          @base_uri = URI.parse(base_url || config.http_target_url || "http://127.0.0.1:3000")
          @secret = secret
          @connections = {}
          @mutex = Mutex.new
        end

        def name = :http

        def stop!
          @mutex.synchronize do
            @connections.each_value { |http| http.finish if http.started? }
            @connections.clear
          end
          self
        end

        def ready?
          probe = Net::HTTP::Get.new(Execution::IdentityEndpoint::PATH)
          connection.request(probe)
          true
        rescue StandardError
          false
        end

        private

        def perform(request, started_ms)
          response = connection.request(build(request))

          RawResponse.new(
            request: request,
            status: response.code.to_i,
            headers: response.each_header.to_h,
            body: response.body,
            latency_ms: monotonic_ms - started_ms,
            transport: name
          )
        end

        def build(request)
          klass = Net::HTTP.const_get(request.verb.to_s.capitalize)
          http_request = klass.new(request.full_path)

          merged_headers(request).each { |key, value| http_request[key] = value }
          http_request[CollectorMiddleware::REQUEST_ID_HEADER] = request.request_id
          http_request[CollectorMiddleware::SECRET_HEADER] = @secret if @secret

          if request.body
            http_request["content-type"] ||= "application/json"
            http_request.body = request.body.is_a?(String) ? request.body : JSON.generate(request.body)
          end

          http_request
        end

        def connection
          @mutex.synchronize do
            @connections[Thread.current.object_id] ||= start_connection
          end
        end

        def start_connection
          http = Net::HTTP.new(@base_uri.host, @base_uri.port)
          http.use_ssl = @base_uri.scheme == "https"
          http.open_timeout = config.request_timeout
          http.read_timeout = config.request_timeout
          http.keep_alive_timeout = 30
          http.start
          http
        end
      end
    end
  end
end
