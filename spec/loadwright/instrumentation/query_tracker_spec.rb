# frozen_string_literal: true

# The correlation implementation matters more than either transport. This is the
# spec file that proves the subscribe-once design actually attributes correctly,
# including the failure it exists to prevent: cross-request metric bleed under
# concurrency, which produces plausible-looking numbers belonging to the wrong
# endpoint.
RSpec.describe Loadwright::Instrumentation::QueryTracker do
  let(:config) { Loadwright::Configuration.new }

  subject(:tracker) { described_class.new(config: config) }

  after { tracker.stop! }

  describe "#start!" do
    it "subscribes exactly once, so a double start cannot double every count" do
      tracker.start!
      tracker.start!

      tracker.begin_request("a")
      emit_sql("SELECT * FROM posts WHERE id = 1")

      expect(tracker.bucket("a").count).to eq(1)
    end

    it "attributes nothing before it is started" do
      tracker.begin_request("a")
      emit_sql("SELECT * FROM posts")

      expect(tracker.bucket("a").count).to eq(0)
    end
  end

  describe "attribution" do
    before { tracker.start! }

    it "routes events to the open request's bucket" do
      tracker.begin_request("a")
      emit_sql("SELECT * FROM posts")
      emit_sql("SELECT * FROM comments WHERE post_id = 1")
      tracker.end_request("a")

      expect(tracker.bucket("a").count).to eq(2)
    end

    it "records duration and call site per query" do
      config.detect_n_plus_one = true
      tracker.start!
      tracker.begin_request("a")
      emit_sql("SELECT * FROM posts", duration: 2)

      query = tracker.bucket("a").queries.first
      expect(query[:duration_ms]).to be > 0
      # The nearest frame outside this gem's lib/ — here the helper that emitted
      # the event. In a real app it is the model, controller or serializer line
      # that issued the query, which is what makes serializer attribution
      # possible instead of a raw stack trace.
      expect(query[:call_site][:path]).to end_with("execution_helpers.rb")
      expect(query[:call_site][:line]).to be_a(Integer)
    end

    # The named limitation, made visible in data rather than only in docs. A
    # query nobody could attribute is not the same as a query that did not happen.
    it "counts unattributed events instead of dropping them" do
      emit_sql("SELECT * FROM posts")
      emit_sql("SELECT * FROM comments")

      expect(tracker.unattributed_count).to eq(2)
      expect(tracker.to_h[:unattributed_note]).to include("GAP-01")
    end

    it "stops attributing once the request ends" do
      tracker.begin_request("a")
      tracker.end_request("a")
      emit_sql("SELECT * FROM posts")

      expect(tracker.bucket("a").count).to eq(0)
      expect(tracker.unattributed_count).to eq(1)
    end

    [
      ["BEGIN", "TRANSACTION"],
      ["COMMIT", "TRANSACTION"],
      ["SAVEPOINT active_record_1", nil],
      ["SET statement_timeout = 10000", nil],
      ["SELECT 1", "SCHEMA"]
    ].each do |sql, name|
      it "ignores #{sql.inspect} (#{name || 'no name'}), which is not an application query" do
        tracker.begin_request("a")
        emit_sql(sql, name: name)

        expect(tracker.bucket("a").count).to eq(0)
      end
    end
  end

  # THE FAILURE MODE THIS DESIGN EXISTS TO PREVENT. AS::N subscribers are
  # process-global: the naive per-request subscribe/unsubscribe means a subscriber
  # registered by one request receives every other in-flight request's events too.
  # Under concurrency you get metric bleed, and the numbers look entirely
  # plausible.
  describe "no cross-request bleed under deliberately overlapping requests" do
    before { tracker.start! }

    it "attributes each thread's queries to its own request" do
      # Interleaved on purpose: each thread opens its request, then waits at a
      # barrier so all of them are demonstrably in flight at once, then emits a
      # distinct number of queries.
      barrier = Queue.new
      counts = { "a" => 3, "b" => 7, "c" => 11 }

      threads = counts.map do |request_id, count|
        Thread.new do
          tracker.begin_request(request_id)
          barrier << request_id
          # Every request is open before any of them emits.
          sleep 0.01 while barrier.length < counts.size
          count.times { |i| emit_sql("SELECT * FROM posts WHERE id = #{i}", duration: 0) }
          tracker.end_request(request_id)
        end
      end
      threads.each(&:join)

      counts.each do |request_id, expected|
        expect(tracker.bucket(request_id).count).to eq(expected),
                                                    "request #{request_id} got #{tracker.bucket(request_id).count} " \
                                                    "queries, expected #{expected} — metric bleed"
      end
      expect(tracker.unattributed_count).to eq(0)
    end

    it "does not leak one request's fingerprints into another's" do
      done = Queue.new

      a = Thread.new do
        tracker.begin_request("a")
        done << :open
        sleep 0.01 until done.length >= 2
        emit_sql("SELECT * FROM posts", duration: 0)
        tracker.end_request("a")
      end
      b = Thread.new do
        tracker.begin_request("b")
        done << :open
        sleep 0.01 until done.length >= 2
        emit_sql("SELECT * FROM invoices", duration: 0)
        tracker.end_request("b")
      end
      [a, b].each(&:join)

      expect(tracker.bucket("a").queries.map { |q| q[:fingerprint] }).to eq(["SELECT * FROM posts"])
      expect(tracker.bucket("b").queries.map { |q| q[:fingerprint] }).to eq(["SELECT * FROM invoices"])
    end
  end

  describe ".fingerprint" do
    # Two queries differing only by bind value must share a fingerprint, or
    # duplicate detection finds nothing on a textbook N+1.
    it "collapses bind values so a per-row query is one fingerprint" do
      first = described_class.fingerprint('SELECT * FROM "comments" WHERE "post_id" = 1 LIMIT 1')
      second = described_class.fingerprint('SELECT * FROM "comments" WHERE "post_id" = 4271 LIMIT 1')

      expect(first).to eq(second)
    end

    it "collapses string literals, floats, and Postgres positional binds" do
      expect(described_class.fingerprint("SELECT * FROM users WHERE email = 'a@b.com'"))
        .to eq(described_class.fingerprint("SELECT * FROM users WHERE email = 'zzz@qqq.org'"))
      expect(described_class.fingerprint("SELECT * FROM t WHERE score > 1.5"))
        .to eq(described_class.fingerprint("SELECT * FROM t WHERE score > 99.25"))
      expect(described_class.fingerprint("SELECT * FROM t WHERE id = $1")).to eq("SELECT * FROM t WHERE id = ?")
    end

    it "collapses IN lists of differing arity, which is how batching looks" do
      expect(described_class.fingerprint("SELECT * FROM t WHERE id IN (1, 2, 3)"))
        .to eq(described_class.fingerprint("SELECT * FROM t WHERE id IN (7, 8, 9, 10, 11)"))
    end

    it "keeps genuinely different queries distinct" do
      expect(described_class.fingerprint("SELECT * FROM posts WHERE id = 1"))
        .not_to eq(described_class.fingerprint("SELECT * FROM comments WHERE id = 1"))
    end

    it "squeezes whitespace so formatting is not a distinction" do
      expect(described_class.fingerprint("SELECT  *\n  FROM posts")).to eq("SELECT * FROM posts")
    end
  end

  describe "the query cache" do
    # ActiveRecord's query cache dedupes identical queries within a request, so a
    # textbook N+1 can appear as a single query — a confident false negative on
    # exactly the pattern this tool exists to find.
    it "records that it could not be disabled, rather than reporting counts as truthful" do
      # hide_const rather than relying on ActiveRecord being absent:
      # examples/sample_app loads it, so whether it is defined here depends on spec
      # ORDER.
      hide_const("ActiveRecord")
      expect(config.disable_query_cache_during_run).to be(true)

      tracker.start!

      expect(tracker.query_cache_disabled?).to be(false)
      expect(tracker.query_cache_error).to include("ActiveRecord is not loaded")
    end

    it "actually turns the cache off against a real connection pool", :sample_app do
      tracker.start!

      expect(tracker.query_cache_disabled?).to be(true)
      expect(tracker.query_cache_error).to be_nil
      expect(ActiveRecord::Base.connection_pool.query_cache_enabled).to be(false)
    end

    it "does not attempt it when the user turned it off" do
      config.disable_query_cache_during_run = false

      tracker.start!

      expect(tracker.query_cache_error).to be_nil
    end
  end

  describe "#forget" do
    it "releases a bucket, so a long run does not accumulate every request forever" do
      tracker.start!
      tracker.begin_request("a")
      tracker.end_request("a")
      tracker.forget("a")

      expect(tracker.bucket("a")).to be_nil
      expect(tracker.open_request_ids).to be_empty
    end
  end
end
