# frozen_string_literal: true

require "securerandom"
require "loadwright/errors"

module Loadwright
  module Engine
    # Samples database health on a dedicated connection OUTSIDE the pool under test.
    #
    # THAT REQUIREMENT IS THE WHOLE POINT OF THIS CLASS, and it is not a detail:
    # polling through the same pool the load is saturating means the health check is
    # the first thing to fail. You lose visibility exactly when you need it most, and
    # the failure looks like "the database is fine, we just can't reach it" — which is
    # indistinguishable from "the database is fine".
    #
    # So the poller gets its own pool of size 1, via an anonymous abstract
    # ActiveRecord subclass. A spec asserts on the pool OBJECT, not on output.
    #
    # OURS VS SOMEBODY ELSE'S. When a lock wait shows up, whether the BLOCKING session
    # is one of ours decides whether the result is a finding or `inconclusive`:
    # reporting "this endpoint has a lock problem" when a migration was running in
    # another terminal is a false positive that destroys trust in the tool.
    #
    #   Postgres — every Loadwright connection sets application_name to a per-run
    #     marker at pre-flight, so a blocking backend identifies itself.
    #   MySQL — the set of CONNECTION_ID()s we hold is recorded at pre-flight.
    #   Anything else — WE CANNOT TELL, and unknown is treated as EXTERNAL. That is
    #     the conservative direction: it costs a finding we might have been entitled
    #     to, rather than blaming an endpoint for a lock someone else held.
    class HealthPoller
      Sample = Struct.new(
        :at, :adapter, :healthy, :lock_waits, :ungranted_locks, :longest_transaction_s,
        :oldest_idle_in_transaction_s, :pool_size, :pool_busy, :pool_waiting,
        :blocking_sessions, :target_alive, :degraded_reason, :error,
        keyword_init: true
      ) do
        def starved? = !pool_waiting.nil? && pool_waiting.positive?

        def contended?
          return true if lock_waits.to_i.positive?
          return true if ungranted_locks.to_i.positive?
          return true if starved?

          false
        end

        # Any blocker we could positively identify as ours. Unknown does NOT count —
        # see the class comment.
        def blocker_ours?
          Array(blocking_sessions).any? { |session| session[:ours] == true }
        end

        def blocker_external?
          Array(blocking_sessions).any? { |session| session[:ours] != true }
        end

        def to_h
          {
            at: at, adapter: adapter, healthy: healthy, contended: contended?,
            lock_waits: lock_waits, ungranted_locks: ungranted_locks,
            longest_transaction_s: longest_transaction_s,
            oldest_idle_in_transaction_s: oldest_idle_in_transaction_s,
            pool: { size: pool_size, busy: pool_busy, waiting: pool_waiting },
            blocking_sessions: blocking_sessions,
            target_alive: target_alive,
            degraded_reason: degraded_reason,
            error: error
          }.compact
        end
      end

      # SQL this class may never contain. Asserted by a spec on the source, because
      # the prohibition has to survive a future well-meaning "let's just clear the
      # blocker" change.
      #
      # ABSOLUTE RULE: Loadwright observes contention and retreats from it. It never
      # terminates, cancels, or kills a session, and never unlocks tables. If the
      # database is struggling the correct action is always to send it LESS work.
      FORBIDDEN_STATEMENTS = /pg_terminate_backend|pg_cancel_backend|\bKILL\b|UNLOCK\s+TABLES/i

      attr_reader :samples, :marker

      def initialize(config: Loadwright.configuration, server: nil, clock: -> { Time.now }, run_id: nil)
        @config = config
        @server = server
        @clock = clock
        @marker = "loadwright-#{run_id || SecureRandom.hex(4)}"
        @samples = []
        @mutex = Mutex.new
        @thread = nil
        @running = false
        @our_connection_ids = []
      end

      # --------------------------------------------------------------- connection

      # A pool of ONE, separate from the pool under test. Returns nil (and degrades)
      # rather than raising: losing health polling is a reduction in protection to be
      # reported, not a reason to refuse the run.
      def poller_pool
        return @poller_pool if defined?(@poller_pool)

        @poller_pool = build_poller_pool
      end

      def out_of_pool?
        pool = poller_pool
        return false if pool.nil?
        return false unless defined?(::ActiveRecord::Base)

        !pool.equal?(::ActiveRecord::Base.connection_pool)
      end

      def available? = !poller_pool.nil?

      # ------------------------------------------------------------------ sampling

      def sample
        return degraded_sample(unavailable_reason) unless available?

        with_poller_connection do |connection|
          adapter = connection.adapter_name.to_s.downcase

          Sample.new(
            at: @clock.call,
            adapter: connection.adapter_name,
            healthy: true,
            target_alive: target_alive,
            **probe(connection, adapter),
            **pool_stats
          ).tap { |current| record(current) }
        end
      rescue StandardError => e
        degraded_sample("health poll failed: #{e.class}: #{e.message}", error: "#{e.class}: #{e.message}")
      end

      def latest = @mutex.synchronize { @samples.last }

      def start!
        return self if @running
        return self unless available?

        @running = true
        interval = @config.health_poll_interval_ms / 1000.0

        @thread = Thread.new do
          while @running
            sample
            sleep interval
          end
        end
        @thread.name = "loadwright-health-poller"
        self
      end

      # Disconnecting the probe pool is not tidiness, it is required. The pool holds an
      # open connection to the same database the run is writing to, and on SQLite a
      # lingering reader BLOCKS writers — so a leaked probe connection turns the next
      # write into a five-second busy-wait per statement. Found the hard way: it turned
      # a 0.3-second end-to-end run into a multi-minute hang once several runs had
      # happened in one process.
      #
      # It also matters on Postgres and MySQL for the ordinary reason: a connection per
      # run that is never returned is a leak, and this gem is not entitled to one.
      def stop!
        @running = false
        @thread&.kill
        @thread = nil
        disconnect_probe_pool!
        self
      end

      def disconnect_probe_pool!
        return unless defined?(@poller_pool) && @poller_pool

        @poller_pool.disconnect!
      rescue StandardError
        nil
      ensure
        # Cleared so a later #sample rebuilds rather than using a disconnected pool.
        remove_instance_variable(:@poller_pool) if defined?(@poller_pool)
      end

      def running? = @running

      # Records which sessions are ours, so the ours-vs-external check has something
      # to compare against. Called from the guard's pre-flight, on the pool UNDER
      # TEST — these are the connections that will hold the locks.
      def register_our_sessions!
        return self unless defined?(::ActiveRecord::Base)

        pool = ::ActiveRecord::Base.connection_pool
        adapter = pool.db_config.configuration_hash[:adapter].to_s

        if adapter.include?("postgres")
          # application_name travels with the connection and shows up in
          # pg_stat_activity, so a blocking backend identifies itself without us
          # having to track a changing set of pids.
          pool.with_connection { |c| c.execute("SET application_name = #{c.quote(@marker)}") }
        elsif adapter.include?("mysql")
          pool.with_connection do |c|
            id = c.select_value("SELECT CONNECTION_ID()")
            @our_connection_ids << id if id
          end
        end

        self
      rescue StandardError
        # Not fatal: it degrades ours-vs-external to "unknown", which the guard
        # treats as external and therefore as inconclusive rather than a finding.
        self
      end

      def to_h
        current = latest

        {
          available: available?,
          out_of_pool: out_of_pool?,
          marker: @marker,
          interval_ms: @config.health_poll_interval_ms,
          samples_taken: @mutex.synchronize { @samples.length },
          unavailable_reason: available? ? nil : unavailable_reason,
          latest: current&.to_h
        }.compact
      end

      private

      def record(current)
        @mutex.synchronize do
          @samples << current
          # Bounded: a long run at a 250ms interval would otherwise accumulate tens
          # of thousands of samples for no analytical benefit.
          @samples.shift while @samples.length > 500
        end
      end

      def degraded_sample(reason, error: nil)
        Sample.new(
          at: @clock.call, healthy: false, degraded_reason: reason, error: error,
          target_alive: target_alive, **pool_stats
        ).tap { |current| record(current) }
      end

      def build_poller_pool
        return nil unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connected?

        configuration = ::ActiveRecord::Base.connection_pool.db_config.configuration_hash
        settings = configuration.merge(pool: 1)

        # application_name is a Postgres connection parameter, and the sqlite3 and
        # mysql2 adapters reject keys they do not recognise. Only sent where it means
        # something — and it means quite a lot there: it is how a blocking backend
        # identifies itself, and how a human reading pg_stat_activity can see this
        # connection is a probe rather than load.
        settings[:application_name] = "#{@marker}-health" if configuration[:adapter].to_s.include?("postgres")

        probe_model.establish_connection(settings)
        probe_model.connection_pool
      rescue StandardError
        nil
      end

      # ActiveRecord refuses establish_connection on an anonymous class
      # ("Anonymous class is not allowed"), so the probe model has to be a real named
      # constant. Assigning the class to a constant is what gives it the name.
      #
      # One named class means one probe pool per process, which is correct here —
      # there is one run per process — but worth knowing: a second poller in the same
      # process replaces the first one's pool rather than adding to it.
      def probe_model
        return Engine::HealthProbeConnection if Engine.const_defined?(:HealthProbeConnection, false)

        Engine.const_set(
          :HealthProbeConnection,
          Class.new(::ActiveRecord::Base) { self.abstract_class = true }
        )
      end

      def with_poller_connection(&block)
        poller_pool.with_connection(&block)
      end

      def unavailable_reason
        unless defined?(::ActiveRecord::Base)
          return "ActiveRecord is not loaded; database health cannot be polled"
        end
        return "no database connection is established; health cannot be polled" unless ::ActiveRecord::Base.connected?

        "a dedicated out-of-pool connection could not be opened; health polling is unavailable, so " \
          "contention detection falls back to request-path exceptions and latency degradation only"
      end

      # A failure mode :in_process cannot produce: under :http the app process can
      # die or hang outright, and continuing to issue requests into it is pointless.
      # The guard escalates an unresponsive target straight to Rung 5.
      def target_alive
        return nil if @server.nil?

        @server.alive?
      rescue StandardError
        false
      end

      def pool_stats
        return {} unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connected?

        stat = ::ActiveRecord::Base.connection_pool.stat
        { pool_size: stat[:size], pool_busy: stat[:busy], pool_waiting: stat[:waiting] }
      rescue StandardError
        {}
      end

      def probe(connection, adapter)
        if adapter.include?("postgres")
          postgres_probe(connection)
        elsif adapter.include?("mysql")
          mysql_probe(connection)
        else
          # Not a gap to hide. resource-contention.md Tier 2 is explicit: degrade to
          # the pool-stat signal and SAY SO, rather than silently running with less
          # protection than the user expects.
          {
            degraded_reason: "#{connection.adapter_name} has no lock introspection Loadwright can read; " \
                             "contention detection is limited to connection-pool pressure, request-path " \
                             "exceptions, and latency degradation",
            blocking_sessions: []
          }
        end
      end

      def postgres_probe(connection)
        waits = connection.select_all(<<~SQL)
          SELECT a.pid,
                 a.application_name,
                 a.wait_event_type,
                 a.state,
                 pg_blocking_pids(a.pid) AS blocked_by
          FROM pg_stat_activity a
          WHERE a.datname = current_database()
            AND a.wait_event_type = 'Lock'
        SQL

        blocking = waits.flat_map { |row| blocking_sessions_for(connection, row) }.uniq { |s| s[:pid] }

        {
          lock_waits: waits.length,
          ungranted_locks: connection.select_value("SELECT count(*) FROM pg_locks WHERE NOT granted").to_i,
          longest_transaction_s: connection.select_value(<<~SQL).to_f,
            SELECT COALESCE(MAX(EXTRACT(EPOCH FROM (now() - xact_start))), 0)
            FROM pg_stat_activity
            WHERE datname = current_database() AND xact_start IS NOT NULL
          SQL
          oldest_idle_in_transaction_s: connection.select_value(<<~SQL).to_f,
            SELECT COALESCE(MAX(EXTRACT(EPOCH FROM (now() - xact_start))), 0)
            FROM pg_stat_activity
            WHERE datname = current_database() AND state = 'idle in transaction'
          SQL
          blocking_sessions: blocking
        }
      end

      def blocking_sessions_for(connection, row)
        pids = parse_pid_array(row["blocked_by"])
        return [] if pids.empty?

        pids.map do |pid|
          name = connection.select_value(
            "SELECT application_name FROM pg_stat_activity WHERE pid = #{connection.quote(pid)}"
          )

          { pid: pid, application_name: name, ours: name.to_s.start_with?(@marker), blocked_pid: row["pid"] }
        end
      end

      # pg_blocking_pids returns an int[]; adapters hand it back as a Ruby Array or as
      # a "{123,456}" string depending on the version and type map.
      def parse_pid_array(value)
        case value
        when Array then value.compact
        when String then value.scan(/\d+/)
        else []
        end
      end

      def mysql_probe(connection)
        waits = connection.select_all(<<~SQL)
          SELECT requesting_engine_transaction_id AS waiting_trx,
                 blocking_engine_transaction_id AS blocking_trx
          FROM performance_schema.data_lock_waits
        SQL

        blocking = waits.map do |row|
          id = connection.select_value(<<~SQL)
            SELECT trx_mysql_thread_id FROM information_schema.innodb_trx
            WHERE trx_id = #{connection.quote(row['blocking_trx'])}
          SQL

          { pid: id, ours: @our_connection_ids.include?(id) }
        end

        {
          lock_waits: waits.length,
          ungranted_locks: waits.length,
          longest_transaction_s: connection.select_value(<<~SQL).to_f,
            SELECT COALESCE(MAX(TIMESTAMPDIFF(SECOND, trx_started, NOW())), 0)
            FROM information_schema.innodb_trx
          SQL
          blocking_sessions: blocking
        }
      rescue StandardError => e
        # performance_schema.data_lock_waits needs MySQL 8.0; sys.innodb_lock_waits is
        # the 5.7 name. Rather than probe versions, fall back and say so.
        {
          degraded_reason: "MySQL lock introspection is unavailable (#{e.class}); " \
                           "performance_schema.data_lock_waits requires MySQL 8.0+. Contention detection " \
                           "falls back to pool pressure, request-path exceptions, and latency degradation",
          blocking_sessions: []
        }
      end
    end
  end
end
