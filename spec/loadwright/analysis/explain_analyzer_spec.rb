# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::ExplainAnalyzer do
  let(:config) { Loadwright::Configuration.new }

  # Records every statement it is asked to run, so "was this statement ever executed"
  # is an observation rather than an inference from what came back.
  class FakeConnection
    attr_reader :statements

    def initialize(adapter_name: "PostgreSQL", rows: [], counts: {})
      @adapter_name = adapter_name
      @rows = rows
      @counts = counts
      @statements = []
    end

    def adapter_name = @adapter_name

    def select_all(statement)
      @statements << statement
      @rows
    end

    def select_value(statement)
      @statements << statement
      @counts.fetch(statement[/FROM\s+"?([A-Za-z0-9_]+)"?/, 1], 0)
    end

    def execute(statement) = @statements << statement

    def quote_table_name(name) = %("#{name}")
  end

  def candidate(sql, endpoint_key: "GET /posts", fingerprint: "fp")
    described_class::Candidate.new(endpoint_key: endpoint_key, fingerprint: fingerprint,
                                   sql: sql, duration_ms: 400.0)
  end

  def analyzer(connection) = described_class.new(config: config, connection: connection, stdout: StringIO.new)

  # THE RULE THAT MATTERS MOST. EXPLAIN ANALYZE *executes* the statement, so
  # running it on a write performs the write -- on a developer's database, from a
  # tool whose whole premise is that it is safe to run locally.
  describe "the SELECT-only rule" do
    %w[
      INSERT\ INTO\ posts\ (title)\ VALUES\ ('x')
      UPDATE\ posts\ SET\ title\ =\ 'x'
      DELETE\ FROM\ posts\ WHERE\ id\ =\ 1
      TRUNCATE\ posts
      DROP\ TABLE\ posts
      CREATE\ INDEX\ idx\ ON\ posts\ (title)
    ].each do |write|
      it "never runs ANALYZE on #{write.split.first}" do
        connection = FakeConnection.new
        analyzer(connection).analyze([candidate(write)])

        expect(connection.statements.grep(/ANALYZE/)).to be_empty
      end
    end

    it "uses plain EXPLAIN for a write, so a plan is still produced without running it" do
      connection = FakeConnection.new
      analyzer(connection).analyze([candidate("DELETE FROM posts WHERE id = 1")])

      expect(connection.statements).to include("EXPLAIN DELETE FROM posts WHERE id = 1")
    end

    it "records on the plan that the statement was not executed" do
      result = analyzer(FakeConnection.new).analyze([candidate("UPDATE posts SET title = 'x'")])

      expect(result.plans.first.analyzed).to be(false)
      expect(result.to_h[:statements_executed]).to eq(0)
    end

    it "uses ANALYZE for a plain SELECT, which is the whole point of the signal" do
      connection = FakeConnection.new
      analyzer(connection).analyze([candidate("SELECT * FROM posts")])

      expect(connection.statements).to include("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM posts")
    end

    # The list is built into a regex by interpolation, so a stray entry becomes a stray
    # alternative and silently changes what the gate matches. That happened once: a
    # trailing comment inside a %w[] literal turned into four extra alternatives and a
    # capture group, and every behavioural example stayed green because none of them
    # happened to use the affected inputs.
    it "contains only function names, so nothing can leak into the regex it builds" do
      expect(described_class::SIDE_EFFECTING_FUNCTIONS).to all(match(/\A[a-z][a-z0-9_]*\z/))
    end

    describe "#analyzable? -- a whitelist, so an unclassifiable statement is never executed" do
      it "accepts a read" do
        expect(analyzer(FakeConnection.new)).to be_analyzable("SELECT id FROM posts WHERE id = 4")
      end

      # Read-shaped at the top level, deletes rows. A check that only looked at the
      # leading keyword would run this.
      it "rejects a data-modifying CTE hiding behind WITH" do
        sql = "WITH moved AS (DELETE FROM posts RETURNING *) SELECT * FROM moved"

        expect(analyzer(FakeConnection.new)).not_to be_analyzable(sql)
      end

      it "rejects a second statement smuggled in after a semicolon" do
        sql = "SELECT 1; DELETE FROM posts"

        expect(analyzer(FakeConnection.new)).not_to be_analyzable(sql)
      end

      it "accepts a single statement with a harmless trailing semicolon" do
        expect(analyzer(FakeConnection.new)).to be_analyzable("SELECT 1;")
      end

      it "rejects a write hidden inside a comment-stripped statement" do
        sql = "SELECT 1 /* comment */ ; UPDATE posts SET title = 'x'"

        expect(analyzer(FakeConnection.new)).not_to be_analyzable(sql)
      end

      # We cannot see inside a function. nextval advances a sequence; the advisory-lock
      # functions take locks that outlive the statement.
      it "rejects a SELECT calling a function with side effects" do
        expect(analyzer(FakeConnection.new)).not_to be_analyzable("SELECT nextval('posts_id_seq')")
        expect(analyzer(FakeConnection.new)).not_to be_analyzable("SELECT pg_advisory_lock(1)")
      end

      # SELECT ... FOR UPDATE takes real row locks. Rejecting it falls out of the
      # UPDATE keyword rule, and that is the correct outcome rather than a coincidence.
      it "rejects SELECT ... FOR UPDATE, which takes locks" do
        expect(analyzer(FakeConnection.new)).not_to be_analyzable("SELECT * FROM posts FOR UPDATE")
      end

      it "rejects an empty or unparseable statement rather than assuming it is a read" do
        expect(analyzer(FakeConnection.new)).not_to be_analyzable("")
        expect(analyzer(FakeConnection.new)).not_to be_analyzable("   ")
      end
    end
  end

  describe "PostgreSQL" do
    def plan_rows(plan) = [{ "QUERY PLAN" => JSON.generate([{ "Plan" => plan }]) }]

    it "reports a sequential scan over the row threshold" do
      config.seq_scan_row_threshold = 1_000
      rows = plan_rows("Node Type" => "Seq Scan", "Relation Name" => "posts",
                       "Actual Rows" => 50_000, "Plan Rows" => 50_000)

      result = analyzer(FakeConnection.new(rows: rows)).analyze([candidate("SELECT * FROM posts")])

      expect(result.findings.map(&:kind)).to include(:sequential_scan)
      expect(result.findings.first.detail).to include("50000", "posts")
    end

    # Conflating query count with query cost is the pitfall this signal exists for, and
    # the finding text has to say so or the reader will look for an N+1 that is not there.
    it "says why query counting could never have found it" do
      config.seq_scan_row_threshold = 1_000
      rows = plan_rows("Node Type" => "Seq Scan", "Relation Name" => "posts", "Actual Rows" => 50_000)

      result = analyzer(FakeConnection.new(rows: rows)).analyze([candidate("SELECT * FROM posts")])

      expect(result.findings.first.detail).to include("it is one query")
    end

    it "ignores a sequential scan over a small table, where it is the right plan" do
      config.seq_scan_row_threshold = 10_000
      rows = plan_rows("Node Type" => "Seq Scan", "Relation Name" => "settings", "Actual Rows" => 12)

      result = analyzer(FakeConnection.new(rows: rows)).analyze([candidate("SELECT * FROM settings")])

      expect(result.findings).to be_empty
    end

    it "finds a scan nested inside a join rather than only at the top of the plan" do
      config.seq_scan_row_threshold = 1_000
      rows = plan_rows(
        "Node Type" => "Nested Loop",
        "Plans" => [
          { "Node Type" => "Index Scan", "Relation Name" => "authors", "Actual Rows" => 1 },
          { "Node Type" => "Seq Scan", "Relation Name" => "comments", "Actual Rows" => 90_000 }
        ]
      )

      result = analyzer(FakeConnection.new(rows: rows)).analyze([candidate("SELECT * FROM authors")])

      expect(result.findings.map { |f| f.evidence[:table] }).to eq(["comments"])
    end

    it "reports a sort that spilled to disk" do
      rows = plan_rows("Node Type" => "Sort", "Sort Method" => "external merge", "Sort Space Used" => 4_096)

      result = analyzer(FakeConnection.new(rows: rows)).analyze([candidate("SELECT * FROM posts ORDER BY x")])

      expect(result.findings.map(&:kind)).to include(:disk_sort)
    end

    # A wildly wrong estimate is a different fix from a missing index -- ANALYZE the
    # table -- so it must not be reported as one.
    it "reports estimate/actual divergence as stale statistics, not as a missing index" do
      rows = plan_rows("Node Type" => "Index Scan", "Relation Name" => "posts",
                       "Plan Rows" => 3, "Actual Rows" => 90_000)

      result = analyzer(FakeConnection.new(rows: rows)).analyze([candidate("SELECT * FROM posts")])

      expect(result.findings.map(&:kind)).to eq([:stale_statistics])
      expect(result.findings.first.detail).to include("ANALYZE")
    end
  end

  describe "MySQL" do
    it "reports a full table scan from EXPLAIN FORMAT=JSON" do
      config.seq_scan_row_threshold = 1_000
      plan = { "query_block" => { "table" => { "table_name" => "posts", "access_type" => "ALL",
                                              "rows_examined_per_scan" => 40_000 } } }
      connection = FakeConnection.new(adapter_name: "Mysql2", rows: [{ "EXPLAIN" => JSON.generate(plan) }])

      result = analyzer(connection).analyze([candidate("SELECT * FROM posts")])

      expect(result.findings.map(&:kind)).to include(:sequential_scan)
      expect(connection.statements).to include("EXPLAIN FORMAT=JSON SELECT * FROM posts")
    end
  end

  # SQLite gives SCAN vs SEARCH and nothing else -- no rows, no timings. That is fewer
  # signals than Postgres, but it is the signal that matters most, so SQLite is
  # supported rather than dropped into "not available".
  describe "SQLite" do
    it "reports a full scan, using a row count to apply the threshold the plan omits" do
      config.seq_scan_row_threshold = 1_000
      connection = FakeConnection.new(
        adapter_name: "SQLite", rows: [{ "detail" => "SCAN posts" }],
        counts: { "posts" => 40_000 }
      )

      result = analyzer(connection).analyze([candidate("SELECT * FROM posts")])

      expect(result.findings.map(&:kind)).to eq([:sequential_scan])
      expect(result.findings.first.evidence[:rows]).to eq(40_000)
    end

    it "does not report an indexed lookup" do
      connection = FakeConnection.new(adapter_name: "SQLite",
                                      rows: [{ "detail" => "SEARCH posts USING INDEX idx (id=?)" }])

      expect(analyzer(connection).analyze([candidate("SELECT * FROM posts")]).findings).to be_empty
    end

    it "does not report a scan of a small table" do
      config.seq_scan_row_threshold = 10_000
      connection = FakeConnection.new(adapter_name: "SQLite", rows: [{ "detail" => "SCAN settings" }],
                                      counts: { "settings" => 4 })

      expect(analyzer(connection).analyze([candidate("SELECT * FROM settings")]).findings).to be_empty
    end

    # EXPLAIN QUERY PLAN never executes the statement, so SQLite needs no SELECT-only
    # carve-out to be safe. The gate is applied anyway, and this records that the
    # `analyzed` flag stays honest about it.
    it "never claims to have executed a statement, because EXPLAIN QUERY PLAN does not" do
      connection = FakeConnection.new(adapter_name: "SQLite", rows: [])

      result = analyzer(connection).analyze([candidate("SELECT * FROM posts")])

      expect(result.plans.first.analyzed).to be(false)
    end
  end

  describe "degradation" do
    it "is not_applicable when the user turned EXPLAIN off, which is not a coverage gap" do
      config.run_explain_on_slow_queries = false

      state, reason = analyzer(FakeConnection.new).analyze([candidate("SELECT 1")]).detector_state

      expect(state).to eq(:not_applicable)
      expect(reason).to include("run_explain_on_slow_queries is disabled")
    end

    it "is unavailable, and says which adapters work, on an adapter it cannot read" do
      state, reason = analyzer(FakeConnection.new(adapter_name: "Oracle"))
                      .analyze([candidate("SELECT 1")]).detector_state

      expect(state).to eq(:unavailable)
      expect(reason).to include("Oracle", "PostgreSQL, MySQL and SQLite")
    end

    # `connection: false` states the premise rather than relying on ActiveRecord not
    # being loaded -- which it usually IS by the time this file runs, since the sample
    # app boots into the same process.
    it "is unavailable when there is no connection to explain through" do
      state, = described_class.new(config: config, connection: false, stdout: StringIO.new)
                              .analyze([candidate("SELECT 1")]).detector_state

      expect(state).to eq(:unavailable)
    end

    # "Every query was fast" is a CLEAN answer to the index question, not a gap.
    # Treating it as unavailable would turn every fast endpoint inconclusive, which is
    # the coverage flooding the three-state model exists to prevent.
    it "is available when nothing was slow enough to be worth explaining" do
      expect(analyzer(FakeConnection.new).analyze([]).detector_state).to eq(:available)
    end

    it "is unavailable when every EXPLAIN attempt errored" do
      connection = FakeConnection.new
      allow(connection).to receive(:select_all).and_raise(StandardError, "relation does not exist")

      state, reason = analyzer(connection).analyze([candidate("SELECT 1")]).detector_state

      expect(state).to eq(:unavailable)
      expect(reason).to include("relation does not exist")
    end
  end

  describe "#candidates_from" do
    let(:queries) do
      [
        { fingerprint: "a", sql: "SELECT 1", duration_ms: 500.0 },
        { fingerprint: "a", sql: "SELECT 1", duration_ms: 900.0 },
        { fingerprint: "b", sql: "SELECT 2", duration_ms: 700.0 },
        { fingerprint: "c", sql: "SELECT 3", duration_ms: 2.0 }
      ]
    end

    it "takes the slowest example of each distinct fingerprint" do
      candidates = analyzer(FakeConnection.new).candidates_from(queries, endpoint_key: "GET /x")

      expect(candidates.map(&:fingerprint)).to eq(%w[a b])
      expect(candidates.first.duration_ms).to eq(900.0)
    end

    it "skips queries below slow_query_threshold_ms, so the fast ones do not crowd out the slow" do
      candidates = analyzer(FakeConnection.new).candidates_from(queries, endpoint_key: "GET /x")

      expect(candidates.map(&:fingerprint)).not_to include("c")
    end

    it "caps at explain_top_n_queries" do
      config.explain_top_n_queries = 1

      expect(analyzer(FakeConnection.new).candidates_from(queries, endpoint_key: "GET /x").length).to eq(1)
    end

    it "skips cached queries, which never reached the database" do
      cached = [{ fingerprint: "a", sql: "SELECT 1", duration_ms: 900.0, cached: true }]

      expect(analyzer(FakeConnection.new).candidates_from(cached, endpoint_key: "GET /x")).to be_empty
    end

    # Without an exemplar statement there is nothing runnable to explain: a fingerprint
    # is `WHERE id = ?`, and substituting a literal would change the plan.
    it "skips queries with no exemplar statement rather than explaining a fingerprint" do
      no_sql = [{ fingerprint: "a", duration_ms: 900.0 }]

      expect(analyzer(FakeConnection.new).candidates_from(no_sql, endpoint_key: "GET /x")).to be_empty
    end
  end

  # A PLACEHOLDER WITHOUT ITS BINDS IS A MISSING INPUT, NOT AN ERROR.
  #
  # Rails emits a PREPARED statement's SQL with `$1` placeholders and the values
  # separately, and whether a query is prepared depends on a per-connection statement
  # cache that warms during a run -- so the same query arrives sometimes with literals
  # and sometimes with placeholders. EXPLAIN on a Postgres placeholder with no
  # parameters raises, so index analysis failed intermittently; and once a skipped check
  # legitimately blocks a clean verdict, that intermittency reached the headline. Two
  # runs of one commit against the same data reported 18 clean and 20.
  describe "a prepared statement whose binds did not arrive" do
    def candidate(sql, binds: nil)
      described_class::Candidate.new(endpoint_key: "GET /widgets", fingerprint: sql,
                                     sql: sql, duration_ms: 50.0, binds: binds)
    end

    def analyzer_on(dialect)
      described_class.new(config: config).tap do |a|
        allow(a).to receive(:dialect).and_return(dialect)
        allow(a).to receive(:adapter_name).and_return(dialect.to_s)
      end
    end

    it "says so deterministically rather than raising" do
      plan = analyzer_on(:postgresql).send(:explain, candidate("SELECT * FROM widgets WHERE id = $1"))

      expect(plan.error).to include("no bind values")
      expect(plan.error).to include("Loadwright limitation")
      expect(plan.analyzed).to be(false)
    end

    # The same answer on every run, which is the whole point: a stably pessimistic
    # verdict beats one that flips between identical runs.
    it "gives the same answer twice" do
      a = analyzer_on(:postgresql)
      first = a.send(:explain, candidate("SELECT * FROM widgets WHERE id = $1"))
      second = a.send(:explain, candidate("SELECT * FROM widgets WHERE id = $1"))

      expect(first.error).to eq(second.error)
    end

    # MEASURED, not assumed: SQLite plans both `?` and `$1` with nothing bound, so
    # treating any placeholder as unexplainable would remove index analysis from
    # adapters where it works today.
    it "does not withhold a plan from an adapter that can produce one unbound" do
      plan = analyzer_on(:sqlite).send(:explain, candidate("SELECT * FROM widgets WHERE id = ?"))

      expect(plan.error.to_s).not_to include("no bind values")
    end

    it "explains normally once the binds are present" do
      a = analyzer_on(:postgresql)

      expect(a.send(:unbound?, candidate("SELECT * FROM widgets WHERE id = $1", binds: [1]))).to be(false)
    end

    it "is not triggered by a statement with no placeholders at all" do
      a = analyzer_on(:postgresql)

      expect(a.send(:unbound?, candidate("SELECT * FROM widgets WHERE id = 7"))).to be(false)
    end
  end
end
