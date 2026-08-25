# frozen_string_literal: true

module Loadwright
  module History
    # Sanitises anything that might reach a persisted artefact.
    #
    # APPLIED AT COLLECTION TIME, NOT RENDER TIME. That is the whole design
    # constraint (reporting.md). Redacting when a report is rendered leaves the raw
    # values sitting in the persisted run record under tmp/, in the recorded-request
    # file, and in memory for the length of the run — so the next person to open a
    # JSON run record, or to attach one to a bug report, gets the unredacted
    # version. Redacting on the way in means the secret never exists in an artefact
    # at all.
    #
    # It also honours the host app's own `filter_parameters`, because an app has
    # already told Rails which of ITS parameters are sensitive and duplicating that
    # list here would immediately drift from it.
    class Redactor
      PLACEHOLDER = "[FILTERED]"

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      def headers(hash)
        return {} if hash.nil?

        hash.to_h do |name, value|
          [name, redact_header?(name) ? PLACEHOLDER : value]
        end
      end

      # Recurses, because the sensitive key is usually nested — `user: { password: }`
      # far more often than a top-level `password`.
      def params(value)
        case value
        when Hash then value.to_h { |key, nested| [key, redact_param?(key) ? PLACEHOLDER : params(nested)] }
        when Array then value.map { |element| params(element) }
        else value
        end
      end

      # A token in a path or query string. `/reset/abc123?token=xyz` is a real shape,
      # and a path is not obviously a place people look for secrets.
      def path(value)
        return value if value.nil?

        patterns.reduce(value.to_s) do |result, pattern|
          result.gsub(/([?&](?:[^=&]*#{pattern.source}[^=&]*)=)[^&]*/i) { "#{Regexp.last_match(1)}#{PLACEHOLDER}" }
        end
      end

      def body(value) = params(value)

      # THE TWO PLACES REDACTION HAS TO REACH THAT ARE NOT OBVIOUS.
      #
      # Measurement.unavailable(reason) and CapabilityProfile's downgrade causes are
      # free text written by the code that failed, and that code knows exactly the
      # things worth protecting: the target URL, the database host, the path the
      # secret file was at, the user account the process runs as. They read as
      # internal metadata, so it is easy to treat them as exempt -- but they are
      # persisted into every run record and rendered into every report, on the same
      # path as everything else. They get redacted on that same path.
      #
      # WHAT SURVIVES, deliberately. Loopback hosts are kept: "the app at
      # http://127.0.0.1:52341 did not become healthy" is the whole value of the
      # message and names nothing private. It is the NON-loopback host that can name a
      # company's internal infrastructure, and that is what goes.
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 0.0.0.0 ::1].freeze

      # user:password@host in a URL or a connection string. Always redacted, whatever
      # the host -- a password is not less sensitive for being on loopback.
      URL_CREDENTIALS = %r{(?<scheme>[a-z][a-z0-9+.-]*://)(?<credentials>[^/@\s:]+(?::[^/@\s]*)?)@}i

      URL_HOST = %r{(?<scheme>[a-z][a-z0-9+.-]*://)(?<host>[^/\s:?#]+)}i

      def reason(text)
        return text if text.nil?

        result = text.to_s
        result = result.gsub(URL_CREDENTIALS) { "#{Regexp.last_match[:scheme]}#{PLACEHOLDER}@" }
        result = result.gsub(URL_HOST) do
          match = Regexp.last_match
          LOOPBACK_HOSTS.include?(match[:host].downcase) ? match[0] : "#{match[:scheme]}#{PLACEHOLDER}"
        end
        result = redact_home_directory(result)

        patterns.reduce(result) do |carried, pattern|
          # `token=abc`, `password: hunk` and similar inside free text. Anchored on the
          # separator so an ordinary mention of the WORD "token" survives -- an
          # over-redacted reason that hides why a signal is missing defeats the purpose
          # of having a reason at all.
          carried.gsub(/((?:#{pattern.source})[^\s:=]*\s*[:=]\s*)(\S+)/i) { "#{Regexp.last_match(1)}#{PLACEHOLDER}" }
        end
      end

      # THE ONE ENTRY POINT FOR ANYTHING PERSISTED. Walks a whole run record, so a new
      # field added anywhere downstream is covered by default rather than by someone
      # remembering to redact it.
      #
      #   * `:sql` is DROPPED outright. It is the exemplar statement kept for EXPLAIN,
      #     it has its literals intact, and nothing in a report is built from it -- the
      #     fingerprint is. It must not reach an artefact.
      #   * free-text explanation fields get #reason
      #   * sensitive-looking keys get [FILTERED]
      REASON_KEYS = %i[reason cause unavailable detail message explanation summary caveat
                       error aborted_reason].freeze

      DROPPED_KEYS = %i[sql].freeze

      def document(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), out|
            name = key.to_s
            next if DROPPED_KEYS.any? { |dropped| dropped.to_s == name }

            out[key] =
              if redact_param?(key) then PLACEHOLDER
              elsif nested.is_a?(String) && REASON_KEYS.any? { |field| field.to_s == name } then reason(nested)
              else document(nested)
              end
          end
        when Array then value.map { |element| document(element) }
        when String then value
        else value
        end
      end

      def to_h
        {
          header_patterns: @config.redact_header_patterns.map(&:inspect),
          additional_patterns: @config.redact_additional_patterns.map(&:inspect),
          honors_rails_filter_parameters: @config.honor_rails_filter_parameters,
          rails_filter_parameters: rails_filter_parameters.map(&:inspect),
          sql_bind_values_redacted: @config.redact_sql_bind_values,
          response_bodies_included: @config.include_response_bodies
        }
      end

      private

      def redact_header?(name)
        @config.redact_header_patterns.any? { |pattern| name.to_s.match?(pattern) } ||
          @config.redact_additional_patterns.any? { |pattern| name.to_s.match?(pattern) }
      end

      def redact_param?(key)
        name = key.to_s
        patterns.any? { |pattern| name.match?(pattern) }
      end

      def patterns
        @patterns ||= @config.redact_additional_patterns +
                      rails_filter_parameters +
                      # Not derived from redact_header_patterns: /cookie/ as a
                      # parameter filter would redact a legitimate `cookie_consent`
                      # boolean, and over-redaction that hides a real value is its
                      # own kind of misleading report.
                      [/password/i, /secret/i, /token/i, /\bapi[-_]?key\b/i]
      end

      # A home directory names the user. Paths appear in reasons constantly -- the
      # secret file's location, a spec's call site, an OpenAPI document that would not
      # parse -- and the path is the useful part while the account name is not.
      def redact_home_directory(text)
        home = Dir.home
        return text if home.nil? || home.empty? || home == "/"

        text.gsub(home, "~")
      rescue StandardError
        text
      end

      def rails_filter_parameters
        return [] unless @config.honor_rails_filter_parameters
        return [] unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        Array(::Rails.application.config.filter_parameters).filter_map do |filter|
          case filter
          when Regexp then filter
          when String, Symbol then /#{Regexp.escape(filter.to_s)}/i
          end
        end
      rescue StandardError
        []
      end
    end
  end
end
