# frozen_string_literal: true

require "loadwright/measurement"

module Loadwright
  module Instrumentation
    # Server-side query timing from `pg_stat_statements`. Postgres only, optional,
    # and degrades with a stated reason everywhere else.
    #
    # WHY BOTHER, GIVEN QueryTracker ALREADY TIMES QUERIES. The two measure different
    # things and the gap between them is itself a finding:
    #
    #   * QueryTracker measures what the CLIENT observed — server execution plus
    #     network, plus connection acquisition, plus ActiveRecord's own work building
    #     the result.
    #   * pg_stat_statements measures what the SERVER spent executing.
    #
    # A query that is 2ms server-side and 40ms client-side is not a slow query; it is
    # a pool or a serialisation problem, and optimising the SQL would waste the
    # developer's afternoon. This is the same class of misdirection the db/view time
    # breakdown prevents, one layer down.
    #
    # THREE WAYS THIS IS UNAVAILABLE, and each gets its own reason rather than a
    # generic one, because the fix differs: not Postgres (nothing to do), extension
    # not installed (a one-line CREATE EXTENSION), and insufficient privileges (ask
    # a DBA, or accept the gap).
    class PgStatTracker
      Snapshot = Struct.new(:rows, :taken_at, keyword_init: true)

      Entry = Struct.new(:queryid, :query, :calls, :total_ms, :rows, :shared_blks_hit,
                         :shared_blks_read, keyword_init: true) do
        def mean_ms = calls.to_i.zero? ? nil : total_ms / calls

        # A low hit ratio means the query is reading from disk rather than from the
        # buffer cache — which is what an unindexed scan over a growing table looks
        # like from the server's side.
        def cache_hit_ratio
          total = shared_blks_hit.to_i + shared_blks_read.to_i
          return nil if total.zero?

          shared_blks_hit.to_i.fdiv(total)
        end

        def to_h
          { queryid: queryid, query: query, calls: calls, total_ms: total_ms.round(3),
            mean_ms: mean_ms&.round(3), rows: rows, cache_hit_ratio: cache_hit_ratio&.round(3) }
        end
      end

      QUERY = <<~SQL.freeze
        SELECT queryid, query, calls, total_exec_time, rows, shared_blks_hit, shared_blks_read
        FROM pg_stat_statements
        WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      SQL

      def initialize(config: Loadwright.configuration, connection: nil)
        @config = config
        @connection = connection
        @unavailable_reason = nil
        @checked = false
      end

      def enabled? = @config.track_pg_stat_statements

      # Reading the reason must not require having asked #available? first: a report
      # renders the reason, and returning nil because nobody happened to probe would
      # print "server-side timing missing" with no explanation.
      def unavailable_reason
        return "track_pg_stat_statements is disabled" unless enabled?

        ensure_checked!
        @unavailable_reason
      end

      def available?
        return false unless enabled?

        ensure_checked!
        @unavailable_reason.nil?
      end

      def snapshot
        return nil unless available?

        Snapshot.new(rows: fetch_rows, taken_at: Time.now)
      rescue StandardError => e
        @unavailable_reason = "pg_stat_statements could not be read: #{e.class}: #{e.message}"
        nil
      end

      # Per-queryid deltas between two snapshots. Deltas rather than absolutes
      # because pg_stat_statements is CUMULATIVE across the whole server since the
      # last reset — absolute numbers would include every query anyone has ever run
      # against that database, which is not what the run under test did.
      #
      # Deliberately does NOT call pg_stat_statements_reset(): that would destroy
      # statistics another developer or a monitoring tool depends on, which is the
      # same class of intrusion as terminating a session.
      def diff(before, after)
        return [] if before.nil? || after.nil?

        baseline = before.rows.to_h { |row| [row.queryid, row] }

        after.rows.filter_map do |row|
          previous = baseline[row.queryid]
          calls = row.calls - (previous&.calls || 0)
          next if calls <= 0

          Entry.new(
            queryid: row.queryid,
            query: row.query,
            calls: calls,
            total_ms: row.total_ms - (previous&.total_ms || 0),
            rows: row.rows - (previous&.rows || 0),
            shared_blks_hit: row.shared_blks_hit - (previous&.shared_blks_hit || 0),
            shared_blks_read: row.shared_blks_read - (previous&.shared_blks_read || 0)
          )
        end.sort_by { |entry| -entry.total_ms }
      end

      # The slowest queries by server-side total time, which is what to hand a
      # developer rather than the whole table.
      def slowest(before, after, limit: nil)
        diff(before, after).first(limit || @config.explain_top_n_queries)
      end

      def to_h
        {
          enabled: enabled?,
          available: available?,
          unavailable_reason: @unavailable_reason
        }.compact
      end

      private

      def connection
        @connection || (defined?(::ActiveRecord::Base) ? ::ActiveRecord::Base.connection : nil)
      end

      def ensure_checked!
        return if @checked

        @checked = true
        check_availability!
      end

      def check_availability!
        @unavailable_reason = nil
        conn = connection

        if conn.nil?
          return @unavailable_reason = "ActiveRecord is not loaded; pg_stat_statements is unavailable"
        end

        adapter = conn.adapter_name.to_s.downcase
        unless adapter.include?("postgres")
          return @unavailable_reason =
                   "pg_stat_statements is Postgres-only and this database is #{conn.adapter_name}; " \
                   "server-side query timing is unavailable (client-side timing still works)"
        end

        installed = conn.select_value("SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'")
        unless installed
          return @unavailable_reason =
                   "the pg_stat_statements extension is not installed. Enable it with " \
                   "`CREATE EXTENSION pg_stat_statements;` (it also needs to be in " \
                   "shared_preload_libraries) to get server-side query timing."
        end

        # Readable is not the same as installed: a non-superuser without
        # pg_read_all_stats sees only their own statements, or none.
        conn.select_value("SELECT 1 FROM pg_stat_statements LIMIT 1")
        nil
      rescue StandardError => e
        @unavailable_reason =
          "pg_stat_statements is installed but not readable by this database user " \
          "(#{e.class}). Grant pg_read_all_stats, or accept that server-side query " \
          "timing is unavailable."
      end

      def fetch_rows
        connection.select_all(QUERY).map do |row|
          Entry.new(
            queryid: row["queryid"],
            query: row["query"],
            calls: row["calls"].to_i,
            total_ms: row["total_exec_time"].to_f,
            rows: row["rows"].to_i,
            shared_blks_hit: row["shared_blks_hit"].to_i,
            shared_blks_read: row["shared_blks_read"].to_i
          )
        end
      end
    end
  end
end
