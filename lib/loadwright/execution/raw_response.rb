# frozen_string_literal: true

module Loadwright
  module Execution
    # What every transport returns. Deliberately dumb: status, headers, body,
    # wall-clock latency, the correlation id, and the exception if one escaped.
    #
    # It knows nothing about instrumentation, and nothing about whether the
    # response was *good* — that verdict belongs to Analysis::ResponseValidator,
    # which has the schema and the seeded-record context this object does not.
    # Keeping the judgement out of here is what stops "did it 200?" and "did it do
    # the work?" collapsing into one boolean.
    class RawResponse
      attr_reader :request, :status, :headers, :body, :latency_ms, :error, :transport, :app_exception

      def initialize(request:, status: nil, headers: {}, body: nil, latency_ms: nil, error: nil, transport: nil,
                     app_exception: nil)
        @request = request
        @status = status
        @headers = normalize_headers(headers)
        @body = body
        @latency_ms = latency_ms
        @error = error
        @transport = transport
        # THE EXCEPTION THE APPLICATION RESCUED AND RENDERED AS A 500.
        #
        # Distinct from `error`, which is an exception that escaped the request
        # entirely. Rails catches most and renders an error page, so a 500 arrives
        # here looking like an ordinary status with a 30KB HTML body -- and the reader
        # is left to reproduce it themselves to find out what raised. We are in the
        # same process; we already have it. Available under :in_process only.
        @app_exception = app_exception
        freeze
      end

      def request_id = request.request_id

      # An exception escaped the request. Distinguished from a 5xx: an exception
      # may be a contention signal the resource guard must classify, while a 500
      # is an endpoint error the circuit breaker counts.
      def errored? = !error.nil?

      def status_family = status.nil? ? nil : (status / 100)

      def success? = !status.nil? && (200..299).cover?(status)

      def body_bytes = body.nil? ? 0 : body.to_s.bytesize

      def header(name) = @headers[name.to_s.downcase]

      def content_type = header("content-type").to_s

      def json? = content_type.include?("json")

      def to_h
        {
          request: request.to_h,
          status: status,
          latency_ms: latency_ms,
          body_bytes: body_bytes,
          content_type: content_type,
          error: error && "#{error.class}: #{error.message}",
          app_exception: app_exception,
          transport: transport
        }
      end

      private

      # Rack 3 gives lowercase keys, ActionDispatch and Net::HTTP do not. Every
      # lookup downstream would otherwise have to guess, and the one that guessed
      # wrong would silently read nil — which for a metrics header means "no
      # queries measured" rather than "header not found".
      def normalize_headers(headers)
        return {} if headers.nil?

        headers.each_with_object({}) do |(key, value), out|
          out[key.to_s.downcase] = value.is_a?(Array) ? value.join(", ") : value
        end.freeze
      end
    end
  end
end
