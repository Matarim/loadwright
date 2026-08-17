# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module SideEffects
    # Forces ActionMailer to :test, ActiveJob to :test, and blocks outbound HTTP
    # outside the allowlist.
    #
    # Specified in references/production-safety.md (side-effect containment).
    #
    # WHY THIS IS ITS OWN SUBSYSTEM AND NOT AN AFTERTHOUGHT. The environment gate
    # protects the database. It does nothing about the other things an endpoint
    # does when you call it 500 times: a load test against POST /api/v1/orders
    # can send hundreds of real emails, enqueue hundreds of real jobs, fire real
    # webhooks at a partner's sandbox, and burn real third-party API quota — from
    # a developer's laptop, in development, with every environment check passing.
    #
    # WHY UNENFORCEABLE MEANS ABORT. abort_if_containment_unavailable defaults to
    # true, and warn-and-continue would be the wrong default. The user believes
    # they are contained. Silently not being contained is exactly the failure
    # mode that mails 500 real customers from a dev box pointed at a shared
    # staging relay. An aborted run that annoys a developer is an acceptable
    # outcome; that is not.
    #
    # Restoration is registered with Lifecycle rather than left to an `ensure`,
    # because ensure blocks do not run on signals and Ctrl-C is the state a user
    # will most often interrupt from. The `ensure` is still there for the normal
    # path; the registry is what covers the signal path.
    class Containment
      # One containment measure's outcome. `enforced` false with `required` true
      # is the abort case; false with required false means the user turned it off.
      Measure = Struct.new(:name, :requested, :enforced, :detail, keyword_init: true) do
        def to_h = { name: name, requested: requested, enforced: enforced, detail: detail }

        def unenforceable? = requested && !enforced
      end

      MEASURES = %i[mail background_jobs outbound_http].freeze

      attr_reader :measures

      def initialize(config: Loadwright.configuration, lifecycle: nil, stdout: $stdout)
        @config = config
        @lifecycle = lifecycle
        @stdout = stdout
        @measures = []
        @restorers = []
        @installed = false
        @restored = false
      end

      # Installs every enabled measure, then decides whether the run may proceed.
      #
      # Ordering note: the abort check happens AFTER installation, not before
      # each measure, so a report can name every unenforceable measure at once
      # rather than only the first. A user missing both webmock and ActionMailer
      # should learn both facts from one run.
      def install!
        raise ConfigurationError, "containment is already installed" if @installed

        @installed = true
        register_teardown

        @measures = [contain_mail, contain_jobs, contain_outbound_http]

        unenforceable = @measures.select(&:unenforceable?)
        if unenforceable.any?
          if @config.abort_if_containment_unavailable
            restore!
            raise ContainmentError, abort_message(unenforceable)
          end

          warn_unenforceable(unenforceable)
        end

        self
      end

      # Idempotent, LIFO, and never raises. Restoration runs while something else
      # may already be unwinding; raising here would replace the original cause.
      def restore!
        return self if @restored

        @restored = true
        @restorers.reverse_each do |restorer|
          restorer.call
        rescue StandardError => e
          @stdout.puts "loadwright: could not restore #{restorer} after the run: #{e.class}: #{e.message}"
        end
        @restorers.clear
        self
      end

      def enforced?(name)
        measure = @measures.find { |m| m.name == name }
        !measure.nil? && measure.enforced
      end

      # Goes into report metadata: which containment measures were active is part
      # of reading the numbers honestly, since a contained run's latency is
      # optimistic relative to production.
      def to_h
        {
          measures: @measures.map(&:to_h),
          all_requested_enforced: @measures.none?(&:unenforceable?)
        }
      end

      private

      def register_teardown
        @lifecycle&.register("side-effect containment", critical: true) { restore! }
      end

      # ------------------------------------------------------------------- mail

      def contain_mail
        return skipped(:mail) unless @config.suppress_mail_delivery

        unless defined?(::ActionMailer::Base)
          return unenforceable(
            :mail,
            "ActionMailer is not loaded. If this app sends mail through a custom mailer that does " \
            "not go through ActionMailer, Loadwright cannot suppress it — that mail would be sent " \
            "for real, once per request."
          )
        end

        mailer = ::ActionMailer::Base
        original_method = mailer.delivery_method
        original_perform = mailer.perform_deliveries

        # :test collects into ActionMailer::Base.deliveries rather than sending,
        # which also makes mail volume per request a countable signal.
        mailer.delivery_method = :test
        mailer.perform_deliveries = true

        @restorers << lambda do
          mailer.delivery_method = original_method
          mailer.perform_deliveries = original_perform
        end

        enforced(:mail, "ActionMailer::Base.delivery_method forced to :test (was #{original_method.inspect})")
      end

      # ------------------------------------------------------------------- jobs

      def contain_jobs
        return skipped(:background_jobs) unless @config.suppress_background_jobs

        unless defined?(::ActiveJob::Base)
          return unenforceable(
            :background_jobs,
            "ActiveJob is not loaded. A job backend invoked directly (Sidekiq::Client.push, " \
            "Resque.enqueue) bypasses ActiveJob entirely and cannot be suppressed from here — " \
            "those jobs would be enqueued and performed for real."
          )
        end

        base = ::ActiveJob::Base
        original = base.queue_adapter

        # The :test adapter records enqueues instead of performing them. Enqueue
        # volume per request is itself a useful finding — a request enqueuing 200
        # jobs is a finding — so recording is strictly better than dropping.
        base.queue_adapter = :test

        @restorers << -> { base.queue_adapter = original }

        enforced(:background_jobs, "ActiveJob queue adapter forced to :test (was #{original.class.name})")
      end

      # ---------------------------------------------------------- outbound HTTP

      def contain_outbound_http
        return skipped(:outbound_http) unless @config.block_outbound_http

        begin
          require "webmock"
        rescue LoadError
          return unenforceable(
            :outbound_http,
            "webmock is not available. config.block_outbound_http cannot be enforced without it. " \
            "Add `gem \"webmock\"` to the :development, :test group, or set " \
            "config.block_outbound_http = false and accept that requests may call third-party APIs."
          )
        end

        allowlist = Array(@config.outbound_http_allowlist)
        already_enabled = ::WebMock.respond_to?(:net_connect_allowed?) && ::WebMock.net_connect_allowed?

        ::WebMock.enable!
        ::WebMock.disable_net_connect!(allow_localhost: false, allow: allowlist)

        @restorers << lambda do
          ::WebMock.allow_net_connect! if already_enabled
          ::WebMock.disable!
        end

        enforced(:outbound_http, "outbound HTTP blocked except #{allowlist.join(', ')}")
      end

      # ----------------------------------------------------------------- helpers

      def enforced(name, detail) = Measure.new(name: name, requested: true, enforced: true, detail: detail)
      def unenforceable(name, detail) = Measure.new(name: name, requested: true, enforced: false, detail: detail)

      def skipped(name)
        Measure.new(name: name, requested: false, enforced: false,
                    detail: "disabled in configuration")
      end

      def abort_message(unenforceable)
        details = unenforceable.map { |m| "  - #{m.name}: #{m.detail}" }.join("\n")

        <<~MSG.strip
          refusing to run: side-effect containment is enabled but cannot be enforced.

          #{details}

          Loadwright aborts rather than continuing unprotected because you would otherwise believe
          this run was contained when it was not — and an uncontained load test sends real mail,
          performs real jobs, and calls real third-party APIs, once per request.

          Either make the measure enforceable, or turn the specific measure off so the report records
          honestly that it was not in effect. Setting config.abort_if_containment_unavailable = false
          proceeds anyway, with a warning; that is a deliberate acceptance of the above.
        MSG
      end

      def warn_unenforceable(unenforceable)
        @stdout.puts "loadwright: WARNING running with UNENFORCED containment " \
                     "(abort_if_containment_unavailable is false):"
        unenforceable.each { |m| @stdout.puts "loadwright:   - #{m.name}: #{m.detail}" }
      end
    end
  end
end
