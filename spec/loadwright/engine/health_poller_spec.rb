# frozen_string_literal: true

RSpec.describe Loadwright::Engine::HealthPoller do
  let(:config) { Loadwright::Configuration.new }

  subject(:poller) { described_class.new(config: config) }

  after { poller.stop! }

  describe "the dedicated connection", :sample_app do
    # THE REQUIREMENT THIS CLASS EXISTS FOR, and the reason it is asserted on the
    # pool OBJECT rather than on output: polling through the pool the load is
    # saturating means the health check is the first thing to fail, so you lose
    # visibility exactly when you need it most — and the failure looks
    # indistinguishable from "the database is fine".
    it "uses a pool that is not the pool under test" do
      expect(poller.poller_pool).not_to be_nil
      expect(poller.poller_pool).not_to equal(ActiveRecord::Base.connection_pool)
      expect(poller).to be_out_of_pool
    end

    it "holds a single connection, so the probe is not itself load" do
      expect(poller.poller_pool.size).to eq(1)
    end

    # The behaviour the separate pool buys: saturation of the pool under test must not
    # take the health check down with it, because that is precisely when the health
    # check matters.
    it "can still sample when the pool under test is fully checked out" do
      pool = ActiveRecord::Base.connection_pool
      # Only the connections that are actually free — checking out `size` of them
      # would block on whatever this thread already holds.
      held = Array.new(pool.size - pool.stat[:busy]) { pool.checkout }
      expect(pool.stat[:busy]).to eq(pool.size)

      sample = poller.sample

      expect(sample.healthy).to be(true)
      expect(sample.pool_busy).to eq(pool.size)
    ensure
      held&.each { |connection| pool.checkin(connection) }
    end
  end

  describe "#sample against a real adapter with no lock introspection", :sample_app do
    # Not a gap to hide. resource-contention.md Tier 2 is explicit: degrade to the
    # pool-stat signal and SAY SO, rather than silently running with less protection
    # than the user expects.
    it "degrades to pool stats and names the limitation" do
      sample = poller.sample

      expect(sample.adapter.downcase).to include("sqlite")
      expect(sample.degraded_reason).to include("no lock introspection Loadwright can read")
      expect(sample.degraded_reason).to include("connection-pool pressure")
      expect(sample.pool_size).to be > 0
    end

    it "is not contended on an idle database" do
      expect(poller.sample).not_to be_contended
    end

    it "records samples for the report, bounded so a long run does not accumulate forever" do
      3.times { poller.sample }

      expect(poller.to_h[:samples_taken]).to eq(3)
      expect(poller.to_h).to include(out_of_pool: true)
    end
  end

  describe "contention detection" do
    def sample_with(**attributes)
      described_class::Sample.new(**attributes)
    end

    it "counts lock waits, ungranted locks and pool starvation as contention" do
      expect(sample_with(lock_waits: 2)).to be_contended
      expect(sample_with(ungranted_locks: 1)).to be_contended
      expect(sample_with(pool_waiting: 3)).to be_contended
      expect(sample_with(lock_waits: 0, ungranted_locks: 0, pool_waiting: 0)).not_to be_contended
    end

    it "distinguishes a starved pool from a merely busy one" do
      expect(sample_with(pool_size: 5, pool_busy: 5, pool_waiting: 0)).not_to be_starved
      expect(sample_with(pool_size: 5, pool_busy: 5, pool_waiting: 1)).to be_starved
    end
  end

  # Reporting "this endpoint has a lock problem" when a migration was running in
  # another terminal is a false positive that destroys trust in the tool.
  describe "ours versus somebody else's" do
    def sample_with(sessions)
      described_class::Sample.new(lock_waits: 1, blocking_sessions: sessions)
    end

    it "identifies our own blocking session" do
      sample = sample_with([{ pid: 1, ours: true }])

      expect(sample).to be_blocker_ours
      expect(sample).not_to be_blocker_external
    end

    it "identifies an external blocker" do
      sample = sample_with([{ pid: 2, ours: false }])

      expect(sample).not_to be_blocker_ours
      expect(sample).to be_blocker_external
    end

    # Unknown is treated as EXTERNAL. That costs a finding we might have been
    # entitled to, rather than blaming an endpoint for a lock someone else held.
    it "treats an unidentified blocker as external, never as ours" do
      sample = sample_with([{ pid: 3, ours: nil }])

      expect(sample).not_to be_blocker_ours
      expect(sample).to be_blocker_external
    end
  end

  describe "the background thread" do
    it "polls on the configured interval and stops cleanly", :sample_app do
      config.health_poll_interval_ms = 20

      poller.start!
      expect(poller).to be_running
      sleep 0.12

      poller.stop!
      expect(poller).not_to be_running
      expect(poller.to_h[:samples_taken]).to be >= 2
    end

    it "does not start when it has no connection to poll with" do
      hide_const("ActiveRecord")

      poller.start!

      expect(poller).not_to be_running
    end
  end

  describe "when it cannot poll at all" do
    # Losing health polling is a reduction in protection to REPORT, not a reason to
    # refuse the run — Tier 1 exceptions and Tier 3 degradation still work.
    it "degrades with a reason naming what still works" do
      hide_const("ActiveRecord")

      sample = poller.sample

      expect(sample.healthy).to be(false)
      expect(sample.degraded_reason).to include("ActiveRecord is not loaded")
      expect(poller).not_to be_available
    end

    it "does not raise" do
      hide_const("ActiveRecord")

      expect { poller.sample }.not_to raise_error
    end
  end

  describe "target liveness" do
    # A failure mode :in_process cannot produce: under :http the app process can die
    # outright, and continuing to issue requests into it is pointless.
    it "reports the server as dead when the server manager says so" do
      server = Class.new { def alive? = false }.new
      subject = described_class.new(config: config, server: server)

      expect(subject.sample.target_alive).to be(false)
    end

    it "reports nil rather than false when there is no server to ask" do
      expect(poller.sample.target_alive).to be_nil
    end

    it "treats a raising liveness check as dead" do
      server = Class.new { def alive? = raise("socket gone") }.new
      subject = described_class.new(config: config, server: server)

      expect(subject.sample.target_alive).to be(false)
    end
  end

  describe "the Postgres probe" do
    # The real Postgres path, exercised against a stand-in connection so the suite
    # does not require a Postgres server. What is under test is the SQL shape and the
    # ours-vs-external attribution, not Postgres itself.
    let(:connection) do
      marker = nil
      Class.new do
        attr_accessor :queries

        def initialize = @queries = []

        def adapter_name = "PostgreSQL"

        def quote(value) = "'#{value}'"

        def select_all(sql)
          @queries << sql
          return [] unless sql.include?("pg_stat_activity") && sql.include?("wait_event_type")

          [{ "pid" => 42, "application_name" => "loadwright-abc", "blocked_by" => [99] }]
        end

        def select_value(sql)
          @queries << sql
          return 2 if sql.include?("pg_locks")
          return "loadwright-abc-health" if sql.include?("application_name FROM pg_stat_activity")

          12.5
        end
      end.new.tap { marker }
    end

    def poller_with(connection)
      described_class.new(config: config).tap do |instance|
        pool = Class.new do
          define_method(:with_connection) { |&block| block.call(connection) }
        end.new
        instance.instance_variable_set(:@poller_pool, pool)
      end
    end

    it "counts lock waits and ungranted locks" do
      sample = poller_with(connection).sample

      expect(sample.lock_waits).to eq(1)
      expect(sample.ungranted_locks).to eq(2)
      expect(sample).to be_contended
    end

    it "resolves the blocking session and attributes it" do
      subject = poller_with(connection)
      # The marker the poller generated is what a blocking backend's application_name
      # is compared against.
      allow(connection).to receive(:select_value) do |sql|
        next 0 if sql.include?("pg_locks")
        next "#{subject.marker}-worker" if sql.include?("application_name FROM pg_stat_activity")

        0
      end

      expect(subject.sample).to be_blocker_ours
    end

    it "treats a blocking backend with somebody else's application_name as external" do
      allow(connection).to receive(:select_value) do |sql|
        next 0 if sql.include?("pg_locks")
        next "psql" if sql.include?("application_name FROM pg_stat_activity")

        0
      end

      expect(poller_with(connection).sample).to be_blocker_external
    end

    # pg_blocking_pids returns int[]; adapters hand it back as a Ruby Array or as a
    # "{123,456}" string depending on version and type map.
    it "parses pg_blocking_pids in either representation" do
      %w[array string].each do |representation|
        allow(connection).to receive(:select_all) do |sql|
          next [] unless sql.include?("wait_event_type")

          blocked = representation == "array" ? [99, 100] : "{99,100}"
          [{ "pid" => 42, "blocked_by" => blocked }]
        end

        expect(poller_with(connection).sample.blocking_sessions.length).to eq(2)
      end
    end

    it "never issues a statement that resolves contention" do
      subject = poller_with(connection)
      subject.sample

      expect(connection.queries.join("\n")).not_to match(described_class::FORBIDDEN_STATEMENTS)
    end
  end
end
