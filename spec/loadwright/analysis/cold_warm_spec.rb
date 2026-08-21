# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::ColdWarm do
  let(:config) { Loadwright::Configuration.new }

  # A cache that records whether it was cleared, so "we left it alone" is an
  # observation rather than an inference.
  def fake_store(class_name)
    Class.new do
      attr_reader :clears

      def initialize = @clears = 0
      def clear = @clears += 1
    end.tap { |k| stub_const(class_name, k) }.new
  end

  def analyzer(cache: nil) = described_class.new(config: config, cache: cache)

  describe "#prepare! -- whose cache is it" do
    # A process-local store affects nobody else, so clearing it is free.
    it "clears a MemoryStore, which nothing else is using" do
      cache = fake_store("ActiveSupport::Cache::MemoryStore")

      expect(analyzer(cache: cache).prepare!).to be(true)
      expect(cache.clears).to eq(1)
    end

    # ==========================================================================
    # THE ONE THAT MATTERS. Rails.cache.clear against Redis or Memcached wipes a cache
    # other processes are using -- possibly a colleague's, on a shared development
    # instance. A diagnostic tool damaging the environment it was pointed at is the
    # category of harm the whole safety design exists to prevent, and a slightly weaker
    # measurement is a trivial price beside it.
    # ==========================================================================
    # The allowlist names the two stores that are provably process-local. EVERYTHING
    # else is treated as shared -- a Redis or Memcached store by name, and equally a
    # store nobody here has heard of, because guessing wrong destroys someone's data
    # and guessing cautiously costs a slightly weaker measurement.
    #
    # (The constant is not stubbed at its real path: touching
    # ActiveSupport::Cache::RedisCacheStore triggers the autoload and demands the redis
    # gem. The name is what the check reads, and this exercises the same branch.)
    ["FakeRedisCacheStore", "FakeMemCacheStore", "SomeCompany::CustomCacheStore"].each do |store|
      it "never clears #{store}, however much better the measurement would be" do
        cache = fake_store(store)

        expect(analyzer(cache: cache).prepare!).to be(false)
        expect(cache.clears).to eq(0)
      end
    end

    it "allows exactly the two stores it can prove are process-local" do
      expect(described_class::PROCESS_LOCAL_STORES)
        .to contain_exactly("ActiveSupport::Cache::MemoryStore", "ActiveSupport::Cache::NullStore")
    end

    it "clears nothing when measure_cold_cache is off" do
      config.measure_cold_cache = false
      cache = fake_store("ActiveSupport::Cache::MemoryStore")

      expect(analyzer(cache: cache).prepare!).to be(false)
      expect(cache.clears).to eq(0)
    end
  end

  describe "#compare" do
    it "reports both passes and the delta, rather than discarding the cold one" do
      result = analyzer.compare([300.0], [30.0], cache_cleared: true)

      expect(result.cold_ms).to eq(300.0)
      expect(result.warm_ms).to eq(30.0)
      expect(result.delta_ms).to eq(270.0)
      expect(result.ratio).to eq(10.0)
    end

    # Overclaiming here would be easy and wrong: we cleared one cache out of three.
    it "labels the measurement application-cache cold, never fully cold" do
      result = analyzer.compare([300.0], [30.0], cache_cleared: true)

      expect(result.label).to eq("application-cache cold")
      expect(result.caveat).to include("OS page cache were not reset")
    end

    it "downgrades the claim to a first-request figure when the cache was left alone" do
      result = analyzer.compare([300.0], [30.0], cache_cleared: false)

      expect(result.caveat).to include("was NOT cleared")
      expect(result.caveat).to include("first-request figure, not a cold one")
    end

    it "is unavailable rather than zero when there was no cold pass" do
      result = analyzer.compare([], [30.0])

      expect(result).not_to be_available
      expect(result.delta_ms).to be_nil
    end
  end

  describe "#finding_for" do
    it "reports an endpoint whose cold case is far worse than its average" do
      finding = analyzer.finding_for("GET /posts", analyzer.compare([900.0], [30.0], cache_cleared: true))

      expect(finding.kind).to eq(:cold_cache_dependency)
      expect(finding.detail).to include("right after a deploy")
    end

    # Ordinary first-request cost -- constant lookup, autoloading, a connection being
    # opened -- is not a cache dependency, and reporting it as one would flag every
    # endpoint in every app.
    it "ignores an ordinary first-request difference" do
      expect(analyzer.finding_for("GET /posts", analyzer.compare([45.0], [30.0]))).to be_nil
    end

    # A RATIO ON SUB-MILLISECOND NUMBERS IS MEANINGLESS. 0.01ms to 0.05ms clears the
    # 3x bar comfortably and is scheduler jitter -- and local requests against a small
    # dev database routinely land there, so the ratio alone would flag essentially
    # every endpoint in the fixture.
    it "ignores a large ratio between two tiny numbers" do
      expect(analyzer.finding_for("GET /posts", analyzer.compare([0.05], [0.01]))).to be_nil
    end

    it "needs both bars: a big absolute gap at a small ratio is not one either" do
      expect(analyzer.finding_for("GET /posts", analyzer.compare([900.0], [800.0]))).to be_nil
    end

    it "carries the caveat into the finding, so the claim travels with the number" do
      finding = analyzer.finding_for("GET /posts", analyzer.compare([900.0], [30.0], cache_cleared: false))

      expect(finding.detail).to include("was NOT cleared")
    end

    it "is nil when the endpoint had no cold pass at all" do
      expect(analyzer.finding_for("GET /posts", nil)).to be_nil
    end
  end
end
