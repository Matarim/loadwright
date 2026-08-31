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

    # `record` runs the host's specs IN THIS PROCESS, against whatever database the CLI
    # booted into -- normally development, because booting the app first makes the
    # `ENV["RAILS_ENV"] ||= "test"` in a conventional rails_helper a no-op. A fully
    # transactional suite rolls everything back; one that truncates between examples
    # would EMPTY that database.
    #
    # When a distinct test database is declared and will not be reached -- which is the
    # detectable, dangerous case -- `record` asks for an acknowledgement rather than
    # only warning. The costs are wildly asymmetric: a transactional suite that runs
    # anyway loses nothing, and a truncating one loses a developer's database
    # irreversibly, so the friction belongs on that side. Not a refusal: the decision
    # is genuinely the user's, and `--accept-database-writes` makes it non-interactively.
    setting :confirm_recording_database, true, section: :safety

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
    # How many times one query fingerprint must repeat inside a single request before
    # it is reported as an N+1 finding.
    #
    # Three, not two, because two identical queries in one request are produced just as
    # readily by two unrelated call sites as by a loop, and a finding on every one of
    # those buries the real ones. Two is still waste: a repeat BELOW this threshold is
    # reported on the endpoint as an observation rather than as a finding, so an
    # endpoint that issues the same query twice never looks identical to one that
    # issues it once. Lower this to 2 to have those reported as findings.
    setting :n_plus_one_duplicate_threshold, 3, section: :response_analysis
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

    # WHAT THE RECORDING ALREADY KNOWS. `record` captures a request the app's own
    # passing spec made, headers and query parameters included -- and the request the
    # run reconstructs from it used to carry neither. An endpoint whose spec sends an
    # Accept header answered 406 on every request; one with a required query parameter
    # answered 400. Both were correctly marked inconclusive, and both were coverage
    # lost to the reconstruction rather than to anything about the app.
    #
    # Headers are replayed by name rather than wholesale: a recording holds the whole
    # relevant header set, and replaying Host or a request id would be wrong. An
    # identity's auth header always wins over a recorded one, and the page-size sweep's
    # parameter always wins over a recorded page size -- otherwise a recorded per_page
    # would silently pin the sweep that exists to vary it.
    setting :replay_recorded_headers, %w[Accept Content-Type].freeze, section: :discovery
    setting :replay_recorded_query_params, true, section: :discovery

    # GRAPHQL. Every operation is a POST to one path, so there are no endpoints to
    # discover -- the unit of work is the named operation, and Loadwright needs to be
    # told where they are. Setting graphql_path turns this on.
    #
    #   config.graphql_path = "/graphql"
    #   config.graphql_document_paths = ["app/graphql/queries/*.graphql"]
    #   config.graphql_operations = [
    #     { name: "PostsWithComments", query: "query PostsWithComments { ... }", variables: {} }
    #   ]
    #
    # Operations are never generated from the schema: a query assembled by
    # introspection exercises field combinations nobody asks for, and measures traffic
    # the app will never receive.
    setting :graphql_path, nil, section: :discovery
    setting :graphql_operations, [].freeze, section: :discovery
    setting :graphql_document_paths, [].freeze, section: :discovery

    # Variable names treated as a connection page size, so the page-size sweep can
    # vary one. An operation that hardcodes `first: 10` cannot be swept; parameterise
    # it as `$first` and it can.
    setting :graphql_page_size_variables, %w[first last pageSize limit].freeze, section: :discovery

    # AUTH
    #
    # How the token from auth_token_provider is attached to each request:
    #   :bearer_token  Authorization: Bearer <token>   (JWT, Doorkeeper, most APIs)
    #   :session       Cookie: <token>                 (Devise and friends)
    #   :header        X-Api-Key: <token>              (API-key APIs)
    # A public API needs none of them: leave auth_token_provider nil and no auth
    # header is sent at all.
    AUTH_STRATEGIES = %i[bearer_token session header].freeze

    setting :auth_strategy, :bearer_token, section: :auth
    setting :auth_token_provider, nil, section: :auth

    # The header name for the :header strategy. It used to be hardcoded to
    # "X-Api-Key", which is one convention among many -- an application whose gateway
    # reads a differently-named header could not be authenticated at all, and every
    # endpoint behind it came back 401 or 500 with no way to say why.
    setting :auth_header_name, "X-Api-Key", section: :auth

    # ONE APPLICATION, MORE THAN ONE CREDENTIAL SCHEME.
    #
    # A Rails app that mounts a second API -- an admin surface, a partner surface, a
    # callback surface -- routinely authenticates it differently from the first. With a
    # single auth_strategy the second mount is unauthenticated on every request, and
    # what a reader sees is a block of endpoints failing identically for a reason the
    # report attributes to their application. Observed for real: fourteen endpoints
    # quarantined across four rounds, diagnosed as a seeding problem, and actually an
    # auth mismatch on a second mount.
    #
    # Each entry overrides the run-level settings for the paths it matches. The first
    # match wins; anything not matched uses the run-level configuration.
    #
    #   config.auth_overrides = [
    #     { paths: [%r{^/internal/partner/}],
    #       strategy: :bearer_token,
    #       token_provider: -> { PartnerToken.mint(5) } }
    #   ]
    setting :auth_overrides, [].freeze, section: :auth

    # Log in the way your clients do, instead of minting a token in this file.
    # Loadwright issues this request once per credential, before the run, through the
    # same transport the run uses. The requests are setup: never measured, never
    # reported as endpoints.
    #
    #   config.auth_login = {
    #     path: "/api/v1/login",
    #     verb: :post,                                  # optional, defaults to :post
    #     credentials: [{ email: "dev@example.com", password: "password" }],
    #     extract: { json: "token" }                    # or { header: "Set-Cookie" }
    #   }
    setting :auth_login, nil, section: :auth
    setting :test_identity_pool_size, 5, section: :auth
    setting :default_headers, { "Accept" => "application/json" }.freeze, section: :auth

    # DATA SEEDING
    setting :factory_bot_enabled, true, section: :seeding
    setting :factory_map, {}.freeze, section: :seeding

    # NON-DATA PRECONDITIONS. Some endpoints need something true that no factory can
    # create -- a feature toggle on, a setting flipped, a cache warmed. Without a hook
    # they are unmeasurable for a reason no seeding change can address, and the report
    # can only say the endpoint failed.
    #
    # Called once, after the safety gate and containment and before any seeding, so
    # anything it touches is inside the run's protections. Restore in `after_run`; both
    # are ordinary callables and neither is retried.
    #
    #   config.before_seed = -> { Flipper.enable(:partner_api) }
    #   config.after_run   = -> { Flipper.disable(:partner_api) }
    setting :before_seed, nil, section: :seeding
    setting :after_run, nil, section: :seeding
    setting :scale_factors, [1, 10, 50, 200].freeze, section: :seeding
    setting :seed_batch_size, 50, section: :seeding
    setting :seed_cleanup_strategy, :delete_created_rows, section: :seeding

    # Also delete rows the APP created while answering requests, not just the ones the
    # factories created. A few hundred POSTs otherwise leave a few hundred records in
    # your database -- and so does a GET that writes an audit row or touches a
    # last_seen_at, which many apps do.
    #
    # Same mechanism as the factories' associated rows: a per-table high-water mark
    # taken before seeding, and only tables that actually received an INSERT. Still
    # strictly id-bounded, still never a TRUNCATE, still incapable of touching a row
    # that existed before the run.
    #
    # WHAT TURNING IT OFF ACTUALLY BUYS, stated precisely because the obvious reading
    # is too generous: it governs tables that ONLY the requests wrote to. A table the
    # FACTORIES also wrote to is swept above the watermark either way -- that is how
    # their own associated rows are cleaned up, and it predates this key.
    #
    # So on a shared database this narrows the blast radius; it does not remove it.
    # The setting that removes it is seed_cleanup_strategy = :leave.
    setting :cleanup_request_created_rows, true, section: :seeding
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
    # Broad on purpose. `/authorization/i` caught `Authorization` and missed
    # `X-Account-Key` -- a real app's real credential, written to a recording in
    # plaintext. Custom auth headers are the norm, not the exception, and the cost of
    # redacting a harmless header is a redacted harmless header.
    setting :redact_header_patterns,
            [/authorization/i, /cookie/i, /api[-_]?key/i, /auth/i, /token/i,
             /secret/i, /credential/i, /session/i, /signature/i, /\Ax-.*-key\z/i].freeze,
            section: :redaction
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

      # Checked here rather than where the header is built: that path only runs once
      # a provider is configured and a request is about to go out, so a typo
      # surfaced mid-run, after seeding, instead of before anything started.
      unless AUTH_STRATEGIES.include?(resolved[:auth_strategy])
        errors << "auth_strategy must be one of #{AUTH_STRATEGIES.join(', ')}"
      end

      Array(resolved[:auth_overrides]).each_with_index do |override, index|
        unless override.is_a?(Hash)
          errors << "auth_overrides[#{index}] must be a Hash of { paths:, strategy:, token_provider: }"
          next
        end

        errors << "auth_overrides[#{index}] needs at least one path pattern" if Array(override[:paths]).empty?

        strategy = override[:strategy]
        next if strategy.nil? || AUTH_STRATEGIES.include?(strategy.to_sym)

        errors << "auth_overrides[#{index}] strategy must be one of #{AUTH_STRATEGIES.join(', ')}"
      end

      # Refused rather than resolved by precedence. Both set means two different
      # answers to "where does the token come from", and silently picking one leaves
      # the user reading an initializer that says something the run did not do.
      if resolved[:auth_login] && resolved[:auth_token_provider]
        errors << "auth_login and auth_token_provider both set; they are two ways to answer " \
                  "the same question. Keep the one you want."
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
