# frozen_string_literal: true

require "json"
require "uri"
require "loadwright/errors"
require "loadwright/execution/identity_endpoint"

module Loadwright
  module Safety
    # Asks a non-loopback :http target what it is, via the unguarded identity
    # endpoint. Trust is asymmetric: the target's self-report is authoritative for
    # REFUSAL and never for approval. Unreachable or unidentified means refuse.
    #
    # Specified in references/production-safety.md (Layer 1b)
    #
    # THE ONE-WAY RATCHET, spelled out because it is the property that makes
    # acting on a self-report safe at all:
    #
    #   target says a disallowed environment -> hard refuse, no override path
    #   target says an allowed environment   -> grants NOTHING; every Layer 3
    #                                           condition still applies in full
    #   target says nothing (unreachable,
    #     wrong shape, non-JSON, timeout)    -> refuse, per fail-closed
    #
    # A wrong or malicious answer can therefore only ever make Loadwright *more*
    # conservative. There is no answer a target can give that unlocks anything,
    # which is why #identify! returns a report rather than a boolean — callers
    # cannot mistake it for an approval.
    class RemoteTargetIdentifier
      # Short by design. This runs before a run starts, and a target that needs
      # more than a couple of seconds to answer three static fields is not a
      # target we should be confident about.
      DEFAULT_TIMEOUT = 3

      Report = Struct.new(:url, :host, :environment, :version, :enabled_here, keyword_init: true) do
        def to_h
          { url: url, host: host, environment: environment, loadwright_version: version, enabled_here: enabled_here }
        end
      end

      # `fetcher` takes a URI and returns the response body as a String, or
      # raises. Injected so the guard's specs never open a socket.
      def initialize(config: Loadwright.configuration, timeout: DEFAULT_TIMEOUT, fetcher: nil)
        @config = config
        @timeout = timeout
        @fetcher = fetcher || method(:http_get)
      end

      # Returns a Report, or raises SafetyError. There is no falsey return: a
      # nil-returning identifier invites `if identifier.identify!(url)`, which is
      # the approval semantics this class must not have.
      def identify!(target_url)
        uri = build_identity_uri(target_url)
        body = fetch(uri, target_url)
        report = parse(body, uri, target_url)

        refuse_disallowed_environment!(report)

        report
      end

      private

      attr_reader :config

      def build_identity_uri(target_url)
        base = URI.parse(target_url.to_s)
        raise SafetyError, "http_target_url #{target_url.inspect} is not an http(s) URL" unless base.host

        base.dup.tap do |uri|
          uri.path = Execution::IdentityEndpoint::PATH
          uri.query = nil
          uri.fragment = nil
        end
      rescue URI::InvalidURIError => e
        raise SafetyError, "http_target_url #{target_url.inspect} could not be parsed: #{e.message}"
      end

      def fetch(uri, target_url)
        @fetcher.call(uri, @timeout)
      rescue StandardError => e
        # Fail closed. An unidentified remote target is exactly the case not to
        # assume anything about.
        raise SafetyError, <<~MSG.strip
          refusing to run: the remote target #{target_url} did not answer Loadwright's identity
          endpoint (#{Execution::IdentityEndpoint::PATH}): #{e.class}: #{e.message}.
          An unidentified remote target is treated as production. If this target is a
          development or staging box you control, ensure it loads the loadwright gem so the
          identity endpoint is mounted, then try again.
        MSG
      end

      def parse(body, uri, target_url)
        data = JSON.parse(body.to_s)
        raise TypeError, "expected a JSON object" unless data.is_a?(Hash)

        environment = data["env"].to_s
        raise KeyError, "no `env` field" if environment.empty?

        Report.new(
          url: target_url.to_s,
          host: uri.host,
          environment: environment,
          version: data["loadwright_version"],
          enabled_here: data["enabled_here"]
        )
      rescue JSON::ParserError, TypeError, KeyError => e
        raise SafetyError, <<~MSG.strip
          refusing to run: the remote target #{target_url} answered #{Execution::IdentityEndpoint::PATH}
          but would not identify itself (#{e.message}). A target that will not say what environment
          it is gets treated as production.
        MSG
      end

      # The refusal half of the asymmetry. No override path, deliberately: not
      # allow_production, not allow_remote_http_target, not
      # --i-understand-the-risk. If the target says it is production, we are done.
      def refuse_disallowed_environment!(report)
        allowed = config.enabled_environments.map(&:to_s)
        return if allowed.include?(report.environment)

        raise SafetyError, <<~MSG.strip
          refusing to run: the remote target #{report.url} reports its environment as
          #{report.environment.inspect}, which is not in enabled_environments (#{allowed.join(', ')}).
          There is no override for this. If that environment name is a development or staging
          environment you intend to load-test, add it to config.enabled_environments in the
          TARGET app and rerun.
        MSG
      end

      def http_get(uri, timeout)
        require "net/http"

        response = Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: timeout,
          read_timeout: timeout
        ) { |http| http.request(Net::HTTP::Get.new(uri)) }

        raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body
      end
    end
  end
end
