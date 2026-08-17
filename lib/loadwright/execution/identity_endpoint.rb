# frozen_string_literal: true

require "json"
require "loadwright/version"

module Loadwright
  module Execution
    # The UNGUARDED half of the Layer 1b split (production-safety.md).
    #
    # THE CIRCULARITY THIS RESOLVES. Loadwright must ask a remote :http target
    # what environment it is *before* approving a run, but the collection
    # endpoint (collector_middleware.rb) mounts only *after* the guard approves.
    # The endpoint that would answer the question does not exist until the
    # question is already answered.
    #
    # So these are two endpoints with different risk profiles, and conflating
    # them was an error. This one is mounted whenever the gem is loaded — which
    # is dev/test-only by Gemfile group — needs no secret, and returns exactly
    # three fields. It leaks essentially nothing.
    #
    # Note the property that makes it safe: if the gem is not loaded in
    # production, this endpoint is not there. If someone HAS loaded it in
    # production, an endpoint answering "production" is precisely the signal the
    # guard wants.
    #
    # DO NOT WIDEN THE PAYLOAD. No SQL, no stack traces, no bind values, no
    # timing, no route list, no config. A spec asserts on the exact key set so a
    # future change cannot quietly grow this into the collection endpoint's
    # payload.
    class IdentityEndpoint
      PATH = "/_loadwright/identity"

      # The only keys this endpoint may ever return.
      PAYLOAD_KEYS = %w[env loadwright_version enabled_here].freeze

      def initialize(app = nil)
        @app = app
      end

      def call(env)
        return respond if identity_request?(env)

        raise "Loadwright::Execution::IdentityEndpoint used without a downstream app" unless @app

        @app.call(env)
      end

      # The payload, as data. Extracted so the guard's own tests and the
      # payload-shape spec do not have to go through Rack.
      def self.payload(config: Loadwright.configuration)
        {
          "env" => current_environment.to_s,
          "loadwright_version" => Loadwright::VERSION,
          "enabled_here" => enabled_here?(config)
        }
      end

      # Whether Loadwright would consent to run in THIS process. Deliberately
      # only the environment allowlist: this is a hint for the operator reading
      # the response, and the asking side treats the whole report as
      # authoritative for refusal only, so nothing downstream trusts it.
      def self.enabled_here?(config)
        config.enabled_environments.map(&:to_s).include?(current_environment.to_s)
      rescue StandardError
        false
      end

      def self.current_environment
        return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env

        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "unknown"
      end

      private

      def identity_request?(env)
        env["PATH_INFO"] == PATH && %w[GET HEAD].include?(env["REQUEST_METHOD"])
      end

      def respond
        body = JSON.generate(self.class.payload)
        [200,
         { "content-type" => "application/json", "cache-control" => "no-store" },
         [body]]
      end
    end
  end
end
