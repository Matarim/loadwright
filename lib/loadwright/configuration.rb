# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  # The Loadwright.configure DSL.
  #
  # Three things here are load-bearing and not stylistic:
  #
  # 1. PROVENANCE. Every resolved key records whether its value came from the
  #    built-in default, a contention profile preset, or an explicit assignment.
  #    configuration.md promises "anything you set explicitly overrides the
  #    preset", which plain attr_accessors cannot honour — they cannot tell
  #    `config.lock_timeout_ms = 3000` apart from the identical default, and the
  #    preset may be assigned before or after the key it would overwrite.
  #
  # 2. RESOLVED-VALUE FINGERPRINTING. run-comparison.md's comparability gate
  #    compares config fingerprints. The fingerprint is computed over *resolved*
  #    values, not assigned ones: two runs with identical explicit config but
  #    different presets are not comparable, and a fingerprint over assignments
  #    would call them comparable and silently produce a meaningless delta.
  #
  # 3. LAZY DEFAULTS. Defaults referencing Rails (Rails.root, the application
  #    module name) are stored as callables and resolved at run start, not when
  #    the attribute is defined — the gem's own specs have no Rails application,
  #    and eager evaluation would either raise on load or freeze a wrong value.
  class Configuration
    Setting = Struct.new(:name, :default, :lazy, :section, keyword_init: true) do
      def default_for(config)
        lazy ? config.instance_exec(&lazy) : default
      end
    end

    PROVENANCES = %i[default preset explicit].freeze

    @settings = {}

    class << self
      attr_reader :settings

      def setting(name, default = nil, lazy: nil, section: nil)
        @settings[name] = Setting.new(name: name, default: default, lazy: lazy, section: section)

        define_method(name) { read(name) }

        define_method(:"#{name}=") do |value|
          @assigned[name] = value
          @provenance[name] = :explicit
          @resolved = nil
          value
        end
      end

      def keys = @settings.keys.freeze
    end

    # EXECUTION MODE — references/execution-modes.md
    setting :execution_mode, :in_process, section: :execution
    setting :allow_in_process_threading, false, section: :execution
    setting :http_server_command, nil, section: :execution
    setting :http_boot_timeout, 30, section: :execution
    setting :http_target_url, nil, section: :execution
    setting :allow_remote_http_target, false, section: :execution

    # SAFETY — references/production-safety.md
    setting :enabled_environments, %i[development test], section: :safety
    setting :production_hostname_patterns,
            [/\.rds\.amazonaws\.com\z/, /^prod-/, /\.internal\z/].freeze,
            section: :safety
    setting :allow_production, false, section: :safety

    # No generic fallback. production-safety.md justifies the app-module-name
    # default specifically so the phrase cannot be guessed generically; a
    # hardcoded string would defeat that. Unresolvable means nil, and the safety
    # guard refuses the production-adjacent path rather than accepting a
    # substitute. On an ordinary dev/test run it is never consulted.
    #
    # Note the explicit nil check rather than `&.` on the whole chain: when Rails
    # is defined but does not respond to #application, the guard expression is
    # `false`, and `false&.class` is FalseClass — which has no
    # #module_parent_name. Safe navigation short-circuits on nil only.
    #
    # The module name is derived here rather than via ActiveSupport's
    # Module#module_parent_name. That method comes from a core_ext this gem does
    # not require, so calling it works only when the host happens to have loaded
    # it — and the failure is a NoMethodError while resolving config, which takes
    # down a run for a reason unrelated to what the user was doing. Splitting the
    # class name gives the same answer for the shape that matters
    # (Acme::Application -> "Acme") and nil for an anonymous class, which is the
    # unresolvable case the guard already handles by refusing.
    setting :confirmation_phrase, section: :safety, lazy: lambda {
      next nil unless defined?(::Rails) && ::Rails.respond_to?(:application)

      app = ::Rails.application
      next nil if app.nil?

      name = app.class.name
      next nil if name.nil? || !name.include?("::")

      name.split("::").first
    }

    setting :allow_mutating_requests, false, section: :safety
    setting :max_error_rate_before_abort, 0.20, section: :safety

    # A run longer than this prints its estimate and asks before starting, so nobody
    # discovers a four-hour sweep by waiting through it.
    setting :long_run_confirmation_threshold_minutes, 10, section: :safety

    # SIDE-EFFECT CONTAINMENT
    setting :suppress_mail_delivery, true, section: :containment
    setting :suppress_background_jobs, true, section: :containment
    setting :block_outbound_http, true, section: :containment
    setting :outbound_http_allowlist, %w[localhost 127.0.0.1].freeze, section: :containment
    setting :abort_if_containment_unavailable, true, section: :containment

    # RESPONSE ANALYSIS — references/response-analysis.md
    setting :require_successful_response, true, section: :response_analysis
    setting :require_schema_valid_response, true, section: :response_analysis
    setting :warn_on_empty_response_with_seeded_data, true, section: :response_analysis
    setting :page_size_parameters, %w[per_page limit page[size] pageSize].freeze, section: :response_analysis
    setting :page_size_sweep, [5, 25, 100].freeze, section: :response_analysis
    setting :detect_overfetching, true, section: :response_analysis
    setting :max_response_bytes_warning, 1_048_576, section: :response_analysis
    setting :payload_growth_correlation_threshold, 0.8, section: :response_analysis
    setting :serializer_attribution, true, section: :response_analysis

    # RESOURCE CONTENTION — references/resource-contention.md
    setting :contention_profile, :balanced, section: :contention
    setting :lock_timeout_ms, 3_000, section: :contention
    setting :statement_timeout_ms, 10_000, section: :contention
    setting :abort_on_unhealthy_baseline, true, section: :contention
    setting :health_poll_interval_ms, 500, section: :contention
    setting :latency_degradation_multiplier, 4.0, section: :contention
    setting :degradation_windows_before_backoff, 3, section: :contention
    setting :backoff_initial_delay_ms, 250, section: :contention
    setting :backoff_multiplier, 2.0, section: :contention
    setting :backoff_max_delay_ms, 15_000, section: :contention
    setting :backoff_jitter, 0.3, section: :contention
    setting :max_backoff_attempts, 4, section: :contention
    setting :post_quarantine_cooldown_ms, 5_000, section: :contention
    setting :max_consecutive_quarantines, 3, section: :contention
    setting :max_health_check_retries, 3, section: :contention

    # DISCOVERY — references/discovery-and-load-engine.md
    setting :openapi_spec_paths, section: :discovery, lazy: lambda {
      rails_root ? [rails_root.join("swagger/v1/swagger.yaml")] : []
    }
    setting :integration_spec_paths, section: :discovery, lazy: lambda {
      rails_root ? [rails_root.join("spec/requests"), rails_root.join("spec/integration")] : []
    }
    setting :route_discovery, true, section: :discovery
    setting :excluded_paths, [%r{^/rails/}, %r{^/admin/}, %r{^/health}].freeze, section: :discovery
    setting :included_paths, nil, section: :discovery
    setting :path_param_overrides, {}.freeze, section: :discovery

    # AUTH
    setting :auth_strategy, :bearer_token, section: :auth
    setting :auth_token_provider, nil, section: :auth
    setting :test_identity_pool_size, 5, section: :auth
    setting :default_headers, { "Accept" => "application/json" }.freeze, section: :auth

    # DATA SEEDING
    setting :factory_bot_enabled, true, section: :seeding
    setting :factory_map, {}.freeze, section: :seeding
    setting :scale_factors, [1, 10, 50, 200].freeze, section: :seeding
    setting :seed_batch_size, 50, section: :seeding
    setting :seed_cleanup_strategy, :delete_created_rows, section: :seeding
    setting :unique_field_generator, nil, section: :seeding

    # LOAD SHAPE
    setting :concurrency_levels, [1, 5, 20].freeze, section: :load_shape
    setting :requests_per_endpoint_per_level, 25, section: :load_shape
    setting :request_timeout, 5, section: :load_shape
    setting :warmup_requests, 3, section: :load_shape

    # INSTRUMENTATION — references/performance-signals.md
    setting :detect_n_plus_one, true, section: :instrumentation
    setting :track_memory_allocations, true, section: :instrumentation
    setting :track_connection_pool, true, section: :instrumentation
    setting :disable_query_cache_during_run, true, section: :instrumentation
    setting :track_time_breakdown, true, section: :instrumentation
    setting :track_gc_stats, true, section: :instrumentation
    setting :run_explain_on_slow_queries, true, section: :instrumentation
    setting :explain_top_n_queries, 5, section: :instrumentation
    setting :seq_scan_row_threshold, 10_000, section: :instrumentation
    setting :measure_cold_cache, true, section: :instrumentation
    setting :track_pg_stat_statements, true, section: :instrumentation
    setting :slow_query_threshold_ms, 100, section: :instrumentation
    setting :min_samples_for_percentiles, { p50: 20, p95: 100, p99: 500 }.freeze, section: :instrumentation
    setting :check_pool_vs_server_threads, true, section: :instrumentation

    # Jobs enqueued PER REQUEST above which the volume is itself a finding.
    #
    # Not zero: enqueuing a job from a POST is ordinary and correct. The finding is
    # about volume -- a request fanning out into 200 jobs is doing something a
    # developer almost certainly did not intend, and containment is what makes it
    # visible at all (the :test adapter records instead of performing).
    setting :jobs_enqueued_warning_threshold, 10, section: :instrumentation

    # RUN HISTORY & COMPARISON — references/run-comparison.md
    setting :run_history_dir, section: :history, lazy: lambda {
      rails_root ? rails_root.join("tmp/loadwright/runs") : "tmp/loadwright/runs"
    }
    setting :run_history_limit, 50, section: :history
    setting :regression_threshold_pct, 20, section: :history
    setting :fail_on_regression, false, section: :history

    # REDACTION — references/reporting.md
    setting :honor_rails_filter_parameters, true, section: :redaction
    setting :redact_header_patterns, [/authorization/i, /cookie/i, /api[-_]?key/i].freeze, section: :redaction
    setting :redact_sql_bind_values, true, section: :redaction
    setting :include_response_bodies, false, section: :redaction
    setting :redact_additional_patterns, [].freeze, section: :redaction

    # THRESHOLDS
    setting :fail_on_n_plus_one, false, section: :thresholds
    setting :p95_latency_budget_ms, { default: 500 }.freeze, section: :thresholds

    # REPORTING
    setting :report_formats, %i[html markdown].freeze, section: :reporting
    setting :report_output_dir, section: :reporting, lazy: lambda {
      rails_root ? rails_root.join("tmp/loadwright") : "tmp/loadwright"
    }
    setting :report_filename_pattern, "%Y%m%d-%H%M%S-report", section: :reporting
    setting :write_partial_report_on_abort, true, section: :reporting

    # NOTIFICATIONS
    setting :slack_webhook_url, nil, section: :notifications

    # Contention presets are data, applied once at resolve time to keys the user
    # did not set explicitly. resource-contention.md Part 6 documents what each
    # trades away.
    CONTENTION_PROFILES = {
      # Shared development database, other people are working in it. Prefers a
      # useless-but-harmless run over any disruption.
      conservative: {
        concurrency_levels: [1, 5].freeze,
        lock_timeout_ms: 1_000,
        statement_timeout_ms: 5_000,
        health_poll_interval_ms: 250,
        latency_degradation_multiplier: 2.0,
        degradation_windows_before_backoff: 2,
        backoff_initial_delay_ms: 500,
        backoff_max_delay_ms: 30_000,
        max_backoff_attempts: 3,
        post_quarantine_cooldown_ms: 15_000,
        max_consecutive_quarantines: 2
      }.freeze,

      # The documented defaults. A local database the developer owns.
      balanced: {}.freeze,

      # Throwaway/containerised database; nothing is lost if it falls over.
      # Still retreats, still never kills sessions.
      aggressive: {
        lock_timeout_ms: 10_000,
        statement_timeout_ms: 30_000,
        health_poll_interval_ms: 1_000,
        latency_degradation_multiplier: 8.0,
        degradation_windows_before_backoff: 5,
        backoff_initial_delay_ms: 100,
        backoff_multiplier: 1.5,
        backoff_max_delay_ms: 5_000,
        max_backoff_attempts: 5,
        post_quarantine_cooldown_ms: 1_000,
        max_consecutive_quarantines: 5,
        max_health_check_retries: 5
      }.freeze
    }.freeze

    # The dimensions run-comparison.md requires to match before two runs may be
    # compared. Anything affecting what was measured belongs here; anything
    # affecting only presentation does not.
    COMPARABILITY_KEYS = %i[
      execution_mode
      scale_factors
      concurrency_levels
      requests_per_endpoint_per_level
      warmup_requests
      page_size_sweep
      suppress_mail_delivery
      suppress_background_jobs
      block_outbound_http
      outbound_http_allowlist
      disable_query_cache_during_run
      seed_cleanup_strategy
    ].freeze

    def initialize
      @assigned = {}
      @provenance = {}
      @resolved = nil
    end

    def read(name)
      resolved.fetch(name)
    end
    alias [] read

    # :default | :preset | :explicit
    def provenance(name)
      resolved # force resolution so preset provenance is recorded
      @provenance.fetch(name, :default)
    end

    def explicitly_set?(name) = @provenance[name] == :explicit

    def explicitly_set_keys = @provenance.select { |_, v| v == :explicit }.keys

    # Resolution order, applied once and memoised:
    #   1. built-in default (lazy defaults evaluated here, not at definition)
    #   2. contention profile preset, for keys the user did not set
    #   3. explicit assignment, which always wins regardless of ordering
    def resolved
      @resolved ||= begin
        values = {}
        self.class.settings.each { |name, s| values[name] = s.default_for(self) }

        preset = CONTENTION_PROFILES.fetch(values[:contention_profile], nil)
        if @assigned.key?(:contention_profile)
          preset = CONTENTION_PROFILES.fetch(@assigned[:contention_profile]) do
            raise ConfigurationError,
                  "unknown contention_profile #{@assigned[:contention_profile].inspect}; " \
                  "expected one of #{CONTENTION_PROFILES.keys.join(', ')}"
          end
        end

        preset&.each do |name, value|
          next if @provenance[name] == :explicit

          values[name] = value
          @provenance[name] = :preset
        end

        @assigned.each { |name, value| values[name] = value }
        values.freeze
      end
    end

    def to_h = resolved.dup

    # Every key with its value and where the value came from. reporting.md
    # requires a resolved-config snapshot in run metadata; provenance is what
    # makes "lock_timeout_ms: 1000" legible as "from the :conservative preset"
    # rather than something the developer chose.
    def snapshot
      resolved.to_h { |name, value| [name, { value: value, from: provenance(name) }] }
    end

    # Stable digest over resolved comparability dimensions only.
    def comparability_fingerprint
      require "digest"
      material = COMPARABILITY_KEYS.map { |k| [k, resolved.fetch(k)].inspect }.join("\n")
      Digest::SHA256.hexdigest(material)[0, 16]
    end

    # Cross-key checks that must fail at startup rather than mid-run.
    def validate!
      errors = []

      unless CONTENTION_PROFILES.key?(resolved[:contention_profile])
        errors << "contention_profile must be one of #{CONTENTION_PROFILES.keys.join(', ')}"
      end

      unless %i[in_process http].include?(resolved[:execution_mode])
        errors << "execution_mode must be :in_process or :http"
      end

      # discovery-and-load-engine.md: the app runs in a separate process under
      # :http and cannot see the harness's open transaction. Caught here rather
      # than surfacing as a mysterious empty database mid-run.
      if resolved[:execution_mode] == :http && resolved[:seed_cleanup_strategy] == :transactional_rollback
        errors << "seed_cleanup_strategy :transactional_rollback is unavailable in :http mode " \
                  "(the app runs in a separate process and will not see the harness transaction); " \
                  "use :delete_created_rows"
      end

      raise ConfigurationError, errors.join("; ") if errors.any?

      true
    end

    private

    def rails_root
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:root)

      ::Rails.root
    end
  end
end
