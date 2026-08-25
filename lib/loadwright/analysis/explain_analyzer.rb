# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/measurement"
require "loadwright/analysis/response_correlator"

module Loadwright
  module Analysis
    # EXPLAIN for the slowest distinct queries, run AFTER the load phase on a
    # SEPARATE connection.
    #
    # WHY IT EXISTS. Query counting will never find a missing index. Loading 10,000
    # rows through a sequential scan is ONE query — flat across every scale factor,
    # invisible to the slope heuristic, and the endpoint reads as clean while getting
    # linearly slower with the table. This is the signal that catches it.
    #
    # THE SAFETY RULE. `EXPLAIN ANALYZE` EXECUTES THE STATEMENT. Running it on an
    # INSERT/UPDATE/DELETE performs the write — on a developer's database, from a
    # tool whose entire premise is that it is safe to run locally.
    #
    # So ANALYZE is used on SELECT ONLY, decided by a whitelist and not a blacklist:
    # a statement is eligible only if it positively matches a read-shaped form AND
    # contains no data-modifying keyword anywhere AND is a single statement. Anything
    # else — including anything we cannot classify — gets plain EXPLAIN, which
    # produces a plan without running the query.
    #
    # references/performance-signals.md also permits ANALYZE inside an explicitly
    # rolled-back transaction for writes. That path is deliberately NOT implemented.
    # It depends on the statement having no effects outside the transaction, which is
    # false for sequences, advisory locks, `COMMIT`-ing triggers, and anything the
    # statement touches through a foreign data wrapper — and the failure is a write
    # to a real table. The doc's own tiebreak applies: when in doubt, plain EXPLAIN
    # wins, and here there is always doubt.
    #
    # ADAPTERS degrade rather than disappear:
    #
    #   postgresql  EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) — the full treatment
    #   mysql       EXPLAIN FORMAT=JSON — access type and filesort, no timings
    #   sqlite      EXPLAIN QUERY PLAN — SCAN vs SEARCH, which is the core signal
    #   anything else -> unavailable, stated plainly, never guessed at
    class ExplainAnalyzer
      # One query worth explaining. `sql` is the exemplar statement with its literals
      # intact — a fingerprint cannot be explained, and substituting a literal into one
      # would change the plan the planner picks, which is the thing being measured.
      Candidate = Struct.new(:endpoint_key, :fingerprint, :sql, :duration_ms, :call_site,
                             keyword_init: true)

      # What one EXPLAIN produced. `analyzed` records whether the statement was
      # actually executed, so a reader knows whether the row counts are real or
      # estimated — and so the SELECT-only rule is auditable from the output.
      Plan = Struct.new(:endpoint_key, :fingerprint, :adapter, :analyzed, :raw, :error,
                        keyword_init: true) do
        def failed? = !error.nil?

        def to_h = { endpoint: endpoint_key, fingerprint: fingerprint, adapter: adapter,
                     analyzed: analyzed, error: error }.compact
      end

      Result = Struct.new(:adapter, :plans, :findings, :detector_state, keyword_init: true) do
        def to_h
          {
            adapter: adapter,
            queries_explained: plans.count { |plan| !plan.failed? },
            queries_failed: plans.count(&:failed?),
            statements_executed: plans.count { |plan| plan.analyzed },
            findings: findings.map(&:to_h),
            detector_state: detector_state.is_a?(Array) ? detector_state.first : detector_state,
            detector_reason: detector_state.is_a?(Array) ? detector_state.last : nil
          }.compact
        end
      end

      Finding = ResponseCorrelator::Finding

      # A statement is explained with ANALYZE only if it matches this AND trips none
      # of the disqualifiers below. Whitelist, not blacklist.
      READ_SHAPED = /\A\s*(?:SELECT|WITH|TABLE|VALUES)\b/i

      # Any of these anywhere in the statement disqualifies it, including inside a CTE
      # — `WITH moved AS (DELETE FROM x RETURNING *) SELECT * FROM moved` is read-
      # shaped at the top level and deletes rows.
      WRITE_KEYWORDS = /\b(?:INSERT|UPDATE|DELETE|MERGE|UPSERT|REPLACE|TRUNCATE|DROP|CREATE|ALTER|GRANT|
                          REVOKE|COMMENT|COPY|VACUUM|ANALYZE|REINDEX|CALL|DO|LOCK|SET|NOTIFY|
                          REFRESH)\b/xi

      # Postgres and MySQL both let a function call hide a write. We cannot see inside
      # one, so a statement calling any of these is treated as unknown and never gets
      # ANALYZE. NAMED HERE IN ORDER TO REFUSE THEM, which is the opposite of issuing
      # them -- the two session-affecting entries carry the marker the architecture
      # sweep reads, so a definition of the prohibition is not mistaken for a breach of
      # it (and the marker is per-line, so nothing can exempt a whole file).
      # A plain array rather than %w[], because %w[] has no comments: a `#` inside one is
      # just another word, so the marker below would have become four regex alternatives
      # and a capture group. (It did, briefly. A spec now asserts every entry is
      # function-name shaped, so the next version of that mistake fails loudly.)
      SIDE_EFFECTING_FUNCTIONS = [
        "nextval", "setval",
        "pg_advisory_lock", "pg_advisory_xact_lock",
        "lo_import", "lo_export", "dblink", "dblink_exec",
        "pg_terminate_backend", "pg_cancel_backend" # prohibition-definition: refused, never issued (INV-11)
      ].freeze

      NESTED_FUNCTION_WRITE =
        /\b(?:#{SIDE_EFFECTING_FUNCTIONS.map { |name| Regexp.escape(name) }.join('|')})\s*\(/i

      # Estimated rows this far off actual usually means stale statistics, which is a
      # different fix (ANALYZE the table) from a missing index.
      ESTIMATE_DIVERGENCE = 10.0

      # `connection:` takes three meanings, and the third one matters for testing:
      # an object is used as-is, nil means "open one", and false means "there is none
      # and do not open one". Without the third, a spec asserting the no-connection
      # path passes or fails on whether some EARLIER example happened to boot Rails --
      # exactly the order-dependence rake spec:seeds exists to catch.
      def initialize(config: Loadwright.configuration, connection: nil, stdout: $stdout)
        @config = config
        @injected_connection = connection
        @stdout = stdout
        @table_rows = {}
      end

      def enabled? = @config.run_explain_on_slow_queries

      # THE SELECT-ONLY GATE, exposed publicly so it can be specced directly rather
      # than inferred from what EXPLAIN happened to emit.
      def analyzable?(sql)
        statement = strip_comments(sql.to_s)
        return false if statement.strip.empty?
        # Two statements separated by a semicolon: the second one is invisible to
        # every check above if we only look at the first.
        return false if statement.sub(/;\s*\z/, "").include?(";")
        return false unless statement.match?(READ_SHAPED)
        return false if statement.match?(WRITE_KEYWORDS)
        return false if statement.match?(NESTED_FUNCTION_WRITE)

        true
      end

      # Picks the slowest distinct queries per endpoint, capped at
      # explain_top_n_queries. Distinct by FINGERPRINT: explaining the same shape five
      # times with different bind values produces five copies of one finding.
      def candidates_from(queries, endpoint_key:)
        Array(queries)
          .select { |query| query[:sql] }
          .reject { |query| query[:cached] }
          .group_by { |query| query[:fingerprint] }
          .map { |fingerprint, group| [fingerprint, group.max_by { |query| query[:duration_ms].to_f }] }
          .select { |_, slowest| slowest[:duration_ms].to_f >= @config.slow_query_threshold_ms }
          .sort_by { |_, slowest| -slowest[:duration_ms].to_f }
          .first(@config.explain_top_n_queries)
          .map do |fingerprint, slowest|
            Candidate.new(endpoint_key: endpoint_key, fingerprint: fingerprint, sql: slowest[:sql],
                          duration_ms: slowest[:duration_ms], call_site: slowest[:call_site])
          end
      end

      # `query_data` is what separates "we looked at this endpoint's queries and none was
      # slow" from "we never saw its queries at all". Both arrive here as an empty
      # candidate list, and they mean opposite things: the first is a clean answer to the
      # index question, the second is knowing nothing. Without it, an External collector
      # -- which returns no query data by construction -- would report every endpoint as
      # having no index problem.
      def analyze(candidates, query_data: true)
        candidates = Array(candidates)

        return disabled_result if !enabled?
        return no_query_data_result unless query_data
        # Checked BEFORE the connection: if nothing was slow enough to explain, the
        # answer does not depend on our being able to open a connection.
        return nothing_slow_result if candidates.empty?
        return no_connection_result if connection.nil?
        return unsupported_result if dialect.nil?

        apply_timeouts!

        plans = candidates.map { |candidate| explain(candidate) }
        findings = plans.reject(&:failed?).flat_map { |plan| findings_for(plan) }

        Result.new(adapter: adapter_name, plans: plans, findings: findings,
                   detector_state: detector_state_for(plans))
      end

      # ---------------------------------------------------------------- connection

      # A SEPARATE connection, never the app's. performance-signals.md requires
      # EXPLAIN run after the load phase, and running it through the pool the load
      # just finished stressing would both perturb the pool and queue behind it.
      def connection
        return nil if @injected_connection == false
        return @injected_connection if @injected_connection
        return @connection if defined?(@connection)

        @connection = build_connection
      end

      def adapter_name = connection&.adapter_name.to_s

      def dialect
        name = adapter_name.downcase
        return :postgresql if name.include?("postgres")
        return :mysql if name.include?("mysql") || name.include?("trilogy")
        return :sqlite if name.include?("sqlite")

        nil
      end

      def close!
        @pool&.disconnect!
        @pool = nil
        @connection = nil
        self
      end

      private

      def build_connection
        return nil unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connected?

        configuration = ::ActiveRecord::Base.connection_pool.db_config.configuration_hash.merge(pool: 1)
        configuration = configuration.merge(application_name: "loadwright-explain") if
          configuration[:adapter].to_s.include?("postgres")

        model.establish_connection(configuration)
        @pool = model.connection_pool
        @pool.lease_connection
      rescue StandardError => e
        @stdout.puts "loadwright: could not open a connection for EXPLAIN (#{e.class}); index analysis is off"
        nil
      end

      # Same reasoning as HealthPoller's probe model: ActiveRecord refuses
      # establish_connection on an anonymous class, so this has to be a real constant.
      def model
        return Analysis::ExplainConnection if Analysis.const_defined?(:ExplainConnection, false)

        Analysis.const_set(:ExplainConnection, Class.new(::ActiveRecord::Base) { self.abstract_class = true })
      end

      # EXPLAIN runs under the same limits as everything else. A plan on a table being
      # rewritten by a migration in another window should time out, not block the
      # analysis phase behind a lock the tool must never try to clear.
      def apply_timeouts!
        case dialect
        when :postgresql
          execute("SET LOCAL statement_timeout = #{@config.statement_timeout_ms.to_i}")
          execute("SET LOCAL lock_timeout = #{@config.lock_timeout_ms.to_i}")
        when :mysql
          execute("SET SESSION max_execution_time = #{@config.statement_timeout_ms.to_i}")
          execute("SET SESSION innodb_lock_wait_timeout = #{(@config.lock_timeout_ms.to_i / 1000.0).ceil}")
        end
      rescue StandardError
        # Not fatal, and not silent in effect: a plan that then hits a lock fails with
        # its own error, which is recorded on the Plan and shown in the report.
        nil
      end

      # ------------------------------------------------------------------- explain

      def explain(candidate)
        analyzed = analyzable?(candidate.sql)
        statement = explain_statement(candidate.sql, analyzed: analyzed)

        Plan.new(
          endpoint_key: candidate.endpoint_key, fingerprint: candidate.fingerprint,
          adapter: adapter_name, analyzed: analyzed && executes_statement?, raw: select_rows(statement)
        )
      rescue StandardError => e
        Plan.new(endpoint_key: candidate.endpoint_key, fingerprint: candidate.fingerprint,
                 adapter: adapter_name, analyzed: false, error: "#{e.class}: #{e.message}")
      end

      # Whether the ANALYZE form for this dialect actually runs the query. SQLite's
      # EXPLAIN QUERY PLAN never does, which is why SQLite needs no SELECT-only
      # carve-out to be safe — but the gate is applied there anyway, so the rule holds
      # even if the dialect list grows.
      def executes_statement? = dialect != :sqlite

      def explain_statement(sql, analyzed:)
        case dialect
        when :postgresql then analyzed ? "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}" : "EXPLAIN #{sql}"
        when :mysql then "EXPLAIN FORMAT=JSON #{sql}"
        when :sqlite then "EXPLAIN QUERY PLAN #{sql}"
        end
      end

      def select_rows(statement) = connection.select_all(statement).to_a

      def execute(statement) = connection.execute(statement)

      # ------------------------------------------------------------------ findings

      def findings_for(plan)
        case dialect
        when :postgresql then postgres_findings(plan)
        when :mysql then mysql_findings(plan)
        when :sqlite then sqlite_findings(plan)
        else []
        end
      end

      def postgres_findings(plan)
        root = parse_postgres(plan.raw)
        return [] if root.nil?

        findings = []
        walk_postgres(root) do |node|
          findings.concat(postgres_node_findings(plan, node))
        end
        findings
      end

      def postgres_node_findings(plan, node)
        findings = []
        rows = (node["Actual Rows"] || node["Plan Rows"]).to_f

        if node["Node Type"] == "Seq Scan" && rows >= @config.seq_scan_row_threshold
          findings << seq_scan_finding(plan, node["Relation Name"], rows,
                                       filter: node["Filter"] || node["Recheck Cond"])
        end

        if node["Sort Method"].to_s.include?("external")
          findings << Finding.new(
            kind: :disk_sort, confidence: :high,
            detail: "a sort spilled to disk (#{node['Sort Method']}, #{node['Sort Space Used']}kB); " \
                    "the result set is larger than work_mem. Paginate, or sort on an indexed column.",
            evidence: { endpoint: plan.endpoint_key, fingerprint: plan.fingerprint,
                        sort_method: node["Sort Method"], sort_space_kb: node["Sort Space Used"] }
          )
        end

        estimated = node["Plan Rows"].to_f
        actual = node["Actual Rows"]
        if actual && estimated.positive? && divergence(estimated, actual.to_f) >= ESTIMATE_DIVERGENCE
          findings << Finding.new(
            kind: :stale_statistics, confidence: :medium,
            detail: "the planner estimated #{estimated.round} row(s) and got #{actual}; " \
                    "the table statistics are stale. Run ANALYZE on #{node['Relation Name'] || 'the table'} " \
                    "before trusting a plan-based conclusion here.",
            evidence: { endpoint: plan.endpoint_key, fingerprint: plan.fingerprint,
                        estimated_rows: estimated, actual_rows: actual, node: node["Node Type"] }
          )
        end

        findings
      end

      def mysql_findings(plan)
        parsed = parse_json_column(plan.raw)
        return [] if parsed.nil?

        findings = []
        walk_hashes(parsed) do |node|
          rows = node["rows_examined_per_scan"].to_f

          if node["access_type"] == "ALL" && rows >= @config.seq_scan_row_threshold
            findings << seq_scan_finding(plan, node["table_name"], rows, filter: node["attached_condition"])
          end

          if node["using_filesort"]
            findings << Finding.new(
              kind: :disk_sort, confidence: :medium,
              detail: "MySQL reported using_filesort for this query; the sort is not served by an index.",
              evidence: { endpoint: plan.endpoint_key, fingerprint: plan.fingerprint,
                          table: node["table_name"] }
            )
          end
        end
        findings
      end

      # SQLite reports SCAN <table> for a full scan and SEARCH <table> USING INDEX for
      # an indexed lookup. No row counts and no timings — so the row threshold is
      # applied by counting the table, which is the only way the threshold means
      # anything here. Fewer signals than Postgres, but the signal that matters most.
      def sqlite_findings(plan)
        Array(plan.raw).filter_map do |row|
          detail = row["detail"] || row[:detail]
          table = detail.to_s[/\ASCAN\s+(?:TABLE\s+)?([A-Za-z0-9_]+)/, 1]
          next if table.nil?

          rows = table_row_count(table)
          next if rows.nil? || rows < @config.seq_scan_row_threshold

          seq_scan_finding(plan, table, rows, filter: nil)
        end
      end

      def seq_scan_finding(plan, table, rows, filter:)
        Finding.new(
          kind: :sequential_scan, confidence: :high,
          detail: "a sequential scan read #{rows.to_i} row(s) from #{table || 'a table'}. " \
                  "Query count will never show this — it is one query — but it gets linearly slower " \
                  "as the table grows.#{filter ? " Filter: #{filter}" : ''}",
          evidence: { endpoint: plan.endpoint_key, fingerprint: plan.fingerprint,
                      table: table, rows: rows.to_i, filter: filter }
        )
      end

      # Only for SQLite, where the plan carries no row counts at all. Memoised, and a
      # failure means the finding is skipped rather than reported without its threshold.
      def table_row_count(table)
        return @table_rows[table] if @table_rows.key?(table)

        @table_rows[table] =
          begin
            connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
          rescue StandardError
            nil
          end
      end

      # -------------------------------------------------------------------- parsing

      def parse_postgres(raw)
        parsed = parse_json_column(raw)
        return nil if parsed.nil?

        root = parsed.is_a?(Array) ? parsed.first : parsed
        root.is_a?(Hash) ? root["Plan"] || root : nil
      end

      # Postgres and MySQL both return the JSON plan in a single column whose name
      # differs by version. Take whichever value parses.
      def parse_json_column(raw)
        require "json"

        Array(raw).each do |row|
          row.each_value do |value|
            next unless value.is_a?(String)

            begin
              return JSON.parse(value)
            rescue JSON::ParserError
              next
            end
          end
        end
        nil
      end

      def walk_postgres(node, &block)
        return unless node.is_a?(Hash)

        block.call(node)
        Array(node["Plans"]).each { |child| walk_postgres(child, &block) }
      end

      def walk_hashes(node, &block)
        case node
        when Hash
          block.call(node)
          node.each_value { |value| walk_hashes(value, &block) }
        when Array
          node.each { |value| walk_hashes(value, &block) }
        end
      end

      def divergence(estimated, actual)
        return 0.0 if estimated <= 0 || actual <= 0

        [estimated / actual, actual / estimated].max
      end

      def strip_comments(sql)
        sql.gsub(%r{/\*.*?\*/}m, " ").gsub(/--[^\n]*/, " ")
      end

      # ------------------------------------------------------------ degraded results

      # DISABLED IS :not_applicable, NOT :unavailable. The user turned it off; that is
      # not a gap this run can be blamed for. Everything else here is :unavailable,
      # because the detector was enabled, was asked, and could not answer.
      def disabled_result
        Result.new(adapter: nil, plans: [], findings: [],
                   detector_state: [:not_applicable, "run_explain_on_slow_queries is disabled"])
      end

      def no_query_data_result
        Result.new(adapter: nil, plans: [], findings: [],
                   detector_state: [:unavailable,
                                    "no query data was collected for this endpoint, so there were no " \
                                    "statements to explain (see the collector in run metadata)"])
      end

      def no_connection_result
        Result.new(adapter: nil, plans: [], findings: [],
                   detector_state: [:unavailable,
                                    "no database connection was available for EXPLAIN; index analysis " \
                                    "needs ActiveRecord connected in the harness process"])
      end

      def unsupported_result
        Result.new(adapter: adapter_name, plans: [], findings: [],
                   detector_state: [:unavailable,
                                    "#{adapter_name} has no EXPLAIN output Loadwright can read; index " \
                                    "analysis is available on PostgreSQL, MySQL and SQLite"])
      end

      # NOTHING SLOW ENOUGH IS A CLEAN ANSWER, not a gap. The detector ran, looked at
      # every query the endpoint issued, and found none above slow_query_threshold_ms
      # — which is exactly the result "no index problem here" looks like. Reporting it
      # as :unavailable would turn every fast endpoint inconclusive.
      def nothing_slow_result
        Result.new(adapter: adapter_name, plans: [], findings: [], detector_state: :available)
      end

      def detector_state_for(plans)
        return :available if plans.any? { |plan| !plan.failed? }

        [:unavailable,
         "every EXPLAIN attempt failed (#{plans.filter_map(&:error).uniq.first})"]
      end
    end
  end
end
