# frozen_string_literal: true

require "securerandom"

module Loadwright
  module Execution
    # One concrete request, ready to issue. The engine produces these by resolving
    # a Discovery::Endpoint's path template against real seeded IDs; a transport
    # consumes them without knowing where they came from.
    #
    # The correlation id is generated here rather than in the transport, because
    # the collector needs it before the request is issued — the whole point of
    # subscribing once and routing per event is that the bucket exists first.
    class Request
      SAFE_VERBS = %i[get head options].freeze

      attr_reader :verb, :path, :query, :headers, :body, :request_id, :endpoint_key, :metadata

      def initialize(verb:, path:, query: {}, headers: {}, body: nil, request_id: nil,
                     endpoint_key: nil, metadata: {})
        @verb = verb.to_s.downcase.to_sym
        @path = path
        @query = query.freeze
        @headers = headers.freeze
        @body = body
        @request_id = request_id || self.class.generate_request_id
        @endpoint_key = endpoint_key || "#{@verb.to_s.upcase} #{path}"
        @metadata = metadata.freeze
        freeze
      end

      def self.generate_request_id = "lw-#{SecureRandom.urlsafe_base64(12)}"

      def mutating? = !SAFE_VERBS.include?(verb)

      # Path with the query string appended. Kept here rather than in each
      # transport so :in_process and :http cannot disagree about what was
      # requested — a divergence there would make the two modes incomparable in a
      # way no spec would catch.
      def full_path
        return path if query.nil? || query.empty?

        require "uri"
        separator = path.include?("?") ? "&" : "?"
        "#{path}#{separator}#{URI.encode_www_form(query)}"
      end

      def to_h
        { verb: verb, path: path, query: query, request_id: request_id, endpoint_key: endpoint_key,
          mutating: mutating? }
      end

      def to_s = "#{verb.to_s.upcase} #{full_path}"
    end
  end
end
