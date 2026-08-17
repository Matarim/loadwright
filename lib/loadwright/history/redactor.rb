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
