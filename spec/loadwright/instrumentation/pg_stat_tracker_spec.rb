# frozen_string_literal: true

RSpec.describe Loadwright::Instrumentation::PgStatTracker do
  let(:config) { Loadwright::Configuration.new }

  # A stand-in connection, because the point of these examples is the DEGRADATION
  # paths — and running them against a real Postgres would make the suite depend on
  # a server being installed, which is exactly the situation this class exists to
  # handle gracefully.
  def connection(adapter: "PostgreSQL", extension: true, readable: true, rows: [])
    Class.new do
      define_method(:adapter_name) { adapter }
      define_method(:select_value) do |sql|
        raise "permission denied for pg_stat_statements" if sql.include?("FROM pg_stat_statements") && !readable

        sql.include?("pg_extension") ? (extension ? 1 : nil) : 1
      end
      define_method(:select_all) { |_sql| rows }
    end.new
  end

  describe "availability" do
    it "is available on Postgres with a readable extension" do
      tracker = described_class.new(config: config, connection: connection)

      expect(tracker).to be_available
      expect(tracker.unavailable_reason).to be_nil
    end

    # Each reason is distinct because the fix differs: nothing to do, a one-line
    # CREATE EXTENSION, or ask a DBA.
    it "explains that the database is not Postgres, and that client timing still works" do
      tracker = described_class.new(config: config, connection: connection(adapter: "SQLite"))

      expect(tracker).not_to be_available
      expect(tracker.unavailable_reason).to include("Postgres-only")
      expect(tracker.unavailable_reason).to include("SQLite")
      expect(tracker.unavailable_reason).to include("client-side timing still works")
    end

    it "explains how to install the extension when it is missing" do
      tracker = described_class.new(config: config, connection: connection(extension: false))

      expect(tracker.unavailable_reason).to include("CREATE EXTENSION pg_stat_statements")
      expect(tracker.unavailable_reason).to include("shared_preload_libraries")
    end

    # Installed is not the same as readable: a non-superuser without pg_read_all_stats
    # sees only their own statements, or none.
    it "distinguishes installed-but-unreadable from not installed" do
      tracker = described_class.new(config: config, connection: connection(readable: false))

      expect(tracker).not_to be_available
      expect(tracker.unavailable_reason).to include("not readable by this database user")
      expect(tracker.unavailable_reason).to include("pg_read_all_stats")
    end

    it "explains that ActiveRecord is not loaded" do
      hide_const("ActiveRecord")
      tracker = described_class.new(config: config)

      expect(tracker.unavailable_reason).to include("ActiveRecord is not loaded")
    end

    it "is unavailable when the user turned it off" do
      config.track_pg_stat_statements = false
      tracker = described_class.new(config: config, connection: connection)

      expect(tracker).not_to be_available
    end
  end

  describe "#diff" do
    def row(queryid:, calls:, total:, hit: 0, read: 0, rows: 0)
      { "queryid" => queryid, "query" => "SELECT #{queryid}", "calls" => calls,
        "total_exec_time" => total, "rows" => rows,
        "shared_blks_hit" => hit, "shared_blks_read" => read }
    end

    # pg_stat_statements is CUMULATIVE since the last server reset. Absolute numbers
    # would include every query anyone has ever run against that database, which is
    # not what the run under test did.
    it "returns deltas, not the cumulative totals" do
      before = described_class.new(config: config, connection: connection(rows: [row(queryid: 1, calls: 100,
                                                                                    total: 500.0)])).snapshot
      after = described_class.new(config: config, connection: connection(rows: [row(queryid: 1, calls: 130,
                                                                                   total: 590.0)])).snapshot

      entry = described_class.new(config: config, connection: connection).diff(before, after).first

      expect(entry.calls).to eq(30)
      expect(entry.total_ms).to be_within(0.01).of(90.0)
      expect(entry.mean_ms).to be_within(0.01).of(3.0)
    end

    it "includes a query that appeared only after the run started" do
      before = described_class.new(config: config, connection: connection(rows: [])).snapshot
      after = described_class.new(config: config,
                                  connection: connection(rows: [row(queryid: 7, calls: 5, total: 50.0)])).snapshot

      expect(described_class.new(config: config, connection: connection).diff(before, after).map(&:queryid))
        .to eq([7])
    end

    it "drops a query that was not called during the run" do
      rows = [row(queryid: 1, calls: 10, total: 10.0)]
      before = described_class.new(config: config, connection: connection(rows: rows)).snapshot
      after = described_class.new(config: config, connection: connection(rows: rows)).snapshot

      expect(described_class.new(config: config, connection: connection).diff(before, after)).to be_empty
    end

    it "sorts by server-side total time, worst first" do
      before = described_class.new(config: config, connection: connection(rows: [])).snapshot
      after = described_class.new(config: config, connection: connection(rows: [
                                    row(queryid: 1, calls: 1, total: 5.0),
                                    row(queryid: 2, calls: 1, total: 500.0),
                                    row(queryid: 3, calls: 1, total: 50.0)
                                  ])).snapshot

      expect(described_class.new(config: config, connection: connection).diff(before, after).map(&:queryid))
        .to eq([2, 3, 1])
    end

    # A low hit ratio is what an unindexed scan over a growing table looks like from
    # the server's side.
    it "computes the buffer cache hit ratio" do
      before = described_class.new(config: config, connection: connection(rows: [])).snapshot
      after = described_class.new(config: config,
                                  connection: connection(rows: [row(queryid: 1, calls: 1, total: 1.0,
                                                                    hit: 30, read: 70)])).snapshot

      expect(described_class.new(config: config, connection: connection).diff(before, after).first.cache_hit_ratio)
        .to be_within(0.001).of(0.3)
    end

    it "returns nothing rather than raising when a snapshot is missing" do
      tracker = described_class.new(config: config, connection: connection)

      expect(tracker.diff(nil, nil)).to eq([])
    end
  end

  describe "#slowest" do
    it "limits to explain_top_n_queries" do
      config.explain_top_n_queries = 2
      rows = (1..5).map do |i|
        { "queryid" => i, "query" => "q#{i}", "calls" => 1, "total_exec_time" => i * 10.0,
          "rows" => 0, "shared_blks_hit" => 0, "shared_blks_read" => 0 }
      end
      before = described_class.new(config: config, connection: connection(rows: [])).snapshot
      after = described_class.new(config: config, connection: connection(rows: rows)).snapshot

      slowest = described_class.new(config: config, connection: connection).slowest(before, after)

      expect(slowest.map(&:queryid)).to eq([5, 4])
    end
  end

  # Resetting would destroy statistics another developer or a monitoring tool
  # depends on — the same class of intrusion as terminating a session.
  it "never resets the server's statistics" do
    source = File.read(File.join(SpecPaths::LIB, "instrumentation", "pg_stat_tracker.rb"))
    # Comment lines dropped: the prohibition is STATED in a comment, and that
    # statement is the rule rather than a violation of it.
    code = source.lines.reject { |line| line.strip.start_with?("#") }.join

    expect(code).not_to match(/pg_stat_statements_reset/)
  end

  describe "#to_h" do
    it "records the reason, so a report can say why server-side timing is missing" do
      tracker = described_class.new(config: config, connection: connection(adapter: "Mysql2"))

      expect(tracker.to_h[:unavailable_reason]).to include("Postgres-only")
    end
  end
end
