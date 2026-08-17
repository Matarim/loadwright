# frozen_string_literal: true

require "socket"
require "uri"
require "loadwright/errors"
require "loadwright/safety/confirmation"
require "loadwright/safety/remote_target_identifier"

module Loadwright
  module Safety
    # Layers 1, 1b, 2, 3 and 4 of the production gate: environment allowlist,
    # remote-target identification, hostname heuristics, the four-condition
    # production opt-in, and dry-run-first. Default-deny.
    #
    # Specified in references/production-safety.md
    #
    # Every decision is returned as a Decision value object rather than only
    # printed, because production-safety.md's auditability requirement is that a
    # report can answer "was this run safe?" on its own, without the terminal
    # scrollback.
    class EnvironmentGuard
      # Layer 2, second half. Deliberately warnings rather than hard blocks:
      # plenty of staging environments run on Heroku and Kubernetes too. Held as
      # data so a spec can iterate them instead of naming each one twice.
      PLATFORM_SIGNALS = {
        "DYNO" => "Heroku dyno",
        "KUBERNETES_SERVICE_HOST" => "Kubernetes pod",
        "ECS_CONTAINER_METADATA_URI" => "AWS ECS task",
        "ECS_CONTAINER_METADATA_URI_V4" => "AWS ECS task",
        "FLY_APP_NAME" => "Fly.io machine",
        "RENDER" => "Render service"
      }.freeze

      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1] 0.0.0.0].freeze

      # Where a pattern matched. The report names the source, not just the
      # pattern, because "your hostname looks like production" and "your
      # DATABASE_URL points at production" call for very different reactions.
      HeuristicMatch = Struct.new(:source, :value, :pattern, keyword_init: true) do
        def to_h = { source: source, value: value, pattern: pattern.inspect }
      end

      PlatformSignal = Struct.new(:variable, :description, keyword_init: true) do
        def to_h = { variable: variable, description: description }
      end

      # The auditable record of everything the guard decided. Goes into report
      # metadata verbatim.
      Decision = Struct.new(
        :approved, :environment, :environment_allowlisted, :production_adjacent,
        :adjacency_reasons, :heuristic_matches, :platform_signals,
        :remote_target, :dry_run, :mutating_requests_allowed,
        :production_opt_in_used, :conditions_cleared,
        keyword_init: true
      ) do
        def to_h
          {
            approved: approved,
            environment: environment,
            environment_allowlisted: environment_allowlisted,
            production_adjacent: production_adjacent,
            adjacency_reasons: adjacency_reasons,
            heuristic_matches: heuristic_matches.map(&:to_h),
            platform_signals: platform_signals.map(&:to_h),
            remote_target: remote_target&.to_h,
            dry_run: dry_run,
            mutating_requests_allowed: mutating_requests_allowed,
            production_opt_in_used: production_opt_in_used,
            conditions_cleared: conditions_cleared
          }
        end
      end

      def initialize(config: Loadwright.configuration,
                     confirmation: nil,
                     identifier: nil,
                     env: ENV,
                     hostname: nil,
                     stdout: $stdout)
        @config = config
        @confirmation = confirmation || Confirmation.new
        @identifier = identifier || RemoteTargetIdentifier.new(config: config)
        @env = env
        @hostname = hostname
        @stdout = stdout
      end

      # Returns a Decision, or raises SafetyError. Nothing downstream may issue a
      # single request until this has returned.
      #
      # `execute` is the CLI's --execute. Its absence means dry run, which is
      # Layer 4: the first pass of any non-development run resolves everything
      # and sends nothing.
      def approve!(risk_acknowledged: false, execute: false)
        environment = detect_environment
        allowlisted = allowlisted?(environment)

        # Layer 2 runs even inside the allowlist, and its results feed Layer 3
        # condition 4, so it is gathered before any refusal decision.
        heuristics = heuristic_matches(environment)
        platform = platform_signals

        remote, remote_reason = evaluate_remote_target(heuristics)

        adjacency = []
        adjacency << "environment #{environment.inspect} is not in enabled_environments" unless allowlisted
        adjacency << remote_reason if remote_reason
        production_adjacent = adjacency.any?

        warn_about(heuristics, platform)

        conditions = if production_adjacent
                       clear_layer_3!(environment, adjacency, heuristics, risk_acknowledged: risk_acknowledged)
                     else
                       []
                     end

        dry_run = !execute
        announce_dry_run(production_adjacent) if production_adjacent && dry_run

        Decision.new(
          approved: true,
          environment: environment,
          environment_allowlisted: allowlisted,
          production_adjacent: production_adjacent,
          adjacency_reasons: adjacency,
          heuristic_matches: heuristics,
          platform_signals: platform,
          remote_target: remote,
          dry_run: dry_run,
          mutating_requests_allowed: config.allow_mutating_requests,
          production_opt_in_used: production_adjacent,
          conditions_cleared: conditions
        )
      end

      # Exposed because the collection endpoint must refuse to mount when the
      # guard flagged the environment as production-adjacent, regardless of other
      # config (execution-modes.md, security requirements).
      #
      # Any error answering the question is answered `true`: a mount decision
      # that cannot be evaluated fails closed.
      def production_adjacent?
        return true unless allowlisted?(detect_environment)

        !evaluate_remote_target([])[1].nil?
      rescue StandardError
        true
      end

      private

      attr_reader :config

      # Rails.env when there is a Rails; otherwise the raw environment
      # variables. An unset environment resolves to "unknown", which is NOT in
      # the default allowlist — so a deploy setup that loses RAILS_ENV fails
      # closed rather than defaulting to development.
      def detect_environment
        if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env
          return ::Rails.env.to_s
        end

        value = @env["RAILS_ENV"] || @env["RACK_ENV"]
        value.to_s.strip.empty? ? "unknown" : value.to_s
      end

      def allowlisted?(environment)
        config.enabled_environments.map(&:to_s).include?(environment.to_s)
      end

      # ------------------------------------------------------------------ Layer 2

      def heuristic_matches(_environment)
        candidates = { "hostname" => local_hostname, "DATABASE_URL host" => database_url_host }
        candidates["http_target_url host"] = target_host if target_host

        candidates.compact.flat_map do |source, value|
          config.production_hostname_patterns.filter_map do |pattern|
            HeuristicMatch.new(source: source, value: value, pattern: pattern) if value.match?(pattern)
          end
        end
      end

      def platform_signals
        PLATFORM_SIGNALS.filter_map do |variable, description|
          next if @env[variable].to_s.strip.empty?

          PlatformSignal.new(variable: variable, description: description)
        end
      end

      def local_hostname
        @hostname ||= begin
          Socket.gethostname
        rescue StandardError
          nil
        end
      end

      def database_url_host
        url = @env["DATABASE_URL"]
        return nil if url.to_s.strip.empty?

        URI.parse(url).host
      rescue URI::InvalidURIError
        # A malformed DATABASE_URL is not something to silently treat as clean.
        # Return the raw string so the patterns still get a chance at it.
        url
      end

      def warn_about(heuristics, platform)
        heuristics.each do |match|
          @stdout.puts "loadwright: WARNING #{match.source} #{match.value.inspect} matches " \
                       "production_hostname_patterns #{match.pattern.inspect}"
        end
        platform.each do |signal|
          @stdout.puts "loadwright: WARNING #{signal.variable} is set (#{signal.description}); " \
                       "this process is running on a deployment platform, not a laptop"
        end
      end

      # ----------------------------------------------------------------- Layer 1b

      # Returns [Report_or_nil, adjacency_reason_or_nil].
      def evaluate_remote_target(_heuristics)
        url = config.http_target_url
        return [nil, nil] if url.to_s.strip.empty?
        return [nil, nil] if loopback_target?(url)

        unless config.allow_remote_http_target
          raise SafetyError, <<~MSG.strip
            refusing to run: http_target_url #{url} is not a loopback address, and
            allow_remote_http_target is false. A remote target means the local Rails.env describes
            a different process entirely — every environment check above is inspecting the wrong
            thing. Set config.allow_remote_http_target = true in the initializer if you genuinely
            intend to send load to another machine.
          MSG
        end

        # Ask the target what it is. Refuses on a disallowed environment, on an
        # unreachable target, and on a target that will not identify itself. A
        # successful report grants nothing — the caller still treats this as
        # production-adjacent below.
        report = @identifier.identify!(url)

        [report, "http_target_url #{url} is a non-loopback target (reported environment: " \
                 "#{report.environment.inspect}, which grants nothing)"]
      end

      def loopback_target?(url)
        host = URI.parse(url.to_s).host.to_s
        LOOPBACK_HOSTS.include?(host) || host.match?(/\A127\./) || host.end_with?(".localhost")
      rescue URI::InvalidURIError
        false
      end

      def target_host
        url = config.http_target_url
        return nil if url.to_s.strip.empty?

        URI.parse(url.to_s).host
      rescue URI::InvalidURIError
        nil
      end

      # ------------------------------------------------------------------ Layer 3

      # All four conditions must hold simultaneously. Each is checked
      # independently and names itself in the refusal, so an operator learns
      # which one is missing rather than being told "denied".
      def clear_layer_3!(environment, adjacency, heuristics, risk_acknowledged:)
        cleared = []

        # 1. A config-file change, not a runtime flag, so it cannot be
        #    fat-fingered from the CLI.
        unless config.allow_production
          refuse!(adjacency, <<~MSG)
            config.allow_production is false. This is deliberately an initializer change rather
            than a CLI flag, so that pointing a load test at a production-shaped environment
            cannot be done by editing a shell command.
          MSG
        end
        cleared << :allow_production

        # 3. Checked before the prompt: there is no reason to make someone type
        #    an app name only to then be told a flag was missing.
        unless risk_acknowledged
          refuse!(adjacency, <<~MSG)
            --i-understand-the-risk was not passed. This flag exists so the risk is visible in
            shell history and in any CI or script logs.
          MSG
        end
        cleared << :risk_flag

        # 2. The phrase is app-specific by design. There is deliberately no
        #    generic fallback: a hardcoded "I UNDERSTAND" would be guessable,
        #    which is the entire property the app-module-name default provides.
        phrase = config.confirmation_phrase
        if phrase.to_s.strip.empty?
          refuse!(adjacency, <<~MSG)
            config.confirmation_phrase could not be resolved. It defaults to the Rails
            application's module name, and that is not available here. Loadwright will not
            substitute a generic phrase — a guessable phrase defeats the point of asking for an
            app-specific one. Set config.confirmation_phrase explicitly in the initializer.
          MSG
        end

        @confirmation.obtain!(phrase, prompt: primary_prompt(environment, adjacency))
        cleared << :typed_confirmation

        # 4. A second, separate acknowledgement naming exactly what matched.
        if heuristics.any?
          @confirmation.obtain!(phrase, prompt: heuristic_prompt(heuristics))
          cleared << :heuristic_confirmation
        end

        cleared
      end

      def refuse!(adjacency, detail)
        raise SafetyError, <<~MSG.strip
          refusing to run: this run is production-adjacent (#{adjacency.join('; ')}), which requires
          the full opt-in in production-safety.md Layer 3 — all four conditions, simultaneously.

          #{detail.strip}
        MSG
      end

      def primary_prompt(environment, adjacency)
        <<~PROMPT.strip
          loadwright: PRODUCTION-ADJACENT RUN

            environment:  #{environment}
            because:      #{adjacency.join("\n                        ")}

          This run will seed data and issue requests against that target. If any of the above is
          not what you expect, answer nothing and press enter.
        PROMPT
      end

      def heuristic_prompt(heuristics)
        details = heuristics.map { |m| "  - #{m.source} #{m.value.inspect} matches #{m.pattern.inspect}" }

        <<~PROMPT.strip
          loadwright: PRODUCTION HEURISTICS MATCHED

          #{details.join("\n")}

          Something about this environment looks like production even beyond the environment name.
          Confirm a second time that you still want to proceed.
        PROMPT
      end

      # ------------------------------------------------------------------ Layer 4

      def announce_dry_run(_production_adjacent)
        @stdout.puts <<~MSG
          loadwright: this is a DRY RUN. The endpoint list, scale matrix and request counts will be
          resolved and printed; zero requests will be sent. Re-run with --execute to issue requests.
        MSG
      end
    end
  end
end
