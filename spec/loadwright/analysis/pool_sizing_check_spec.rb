# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::PoolSizingCheck do
  let(:config) { Loadwright::Configuration.new }

  # Real profiles rather than doubles: the whole point of this check is that its two
  # halves degrade differently, and that difference is derived from (transport,
  # collector) -- so a stubbed capability would test the stub.
  let(:http_capability) { Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware) }
  let(:in_process_capability) do
    Loadwright::CapabilityProfile.derive(transport: :in_process, collector: :direct)
  end
  let(:external_capability) { Loadwright::CapabilityProfile.derive(transport: :http, collector: :external) }

  class FakePoolTracker
    attr_reader :peak_busy, :peak_waiting

    def initialize(peak_busy: 0, peak_waiting: 0)
      @peak_busy = peak_busy
      @peak_waiting = peak_waiting
    end
  end

  # The pool size is INJECTED rather than stubbed onto ActiveRecord. These examples run
  # in a process where the sample app may or may not have booted, and a premise that
  # depends on that is a premise that passes or fails on spec order.
  # CONSTRUCTED, not derived, and that is the point. No profile derives
  # connection_pool_exhaustion as available any more: nothing in a run collects pool
  # samples, so advertising the signal would be a claim the tool cannot support, and
  # CapabilityProfile now says so outright.
  #
  # The observed half below is still correct code and still has to keep working, for
  # when the collection endpoint carries pool stats back from the app process the way
  # it already carries time breakdowns. So these examples state the precondition
  # explicitly rather than borrowing a derived profile that no longer offers it.
  def capability_with_pool_observation
    signals = http_capability.signals.merge(
      connection_pool_exhaustion: Loadwright::CapabilityProfile::Capability.new(:available, nil)
    )
    Loadwright::CapabilityProfile.new(signals)
  end

  def check(capability: nil, pool_tracker: nil, pool_size: 5)
    described_class.new(config: config, capability: capability || http_capability,
                        pool_tracker: pool_tracker, pool_provider: -> { pool_size }).check
  end

  describe "the static check -- threads vs pool" do
    it "flags more server threads than pool connections" do
      config.http_server_command = "bundle exec puma --threads 1:16"

      result = check(pool_size: 5)

      expect(result.findings.map(&:kind)).to eq([:pool_smaller_than_server_threads])
    end

    # The point the finding text has to make, or the reader goes looking at SQL.
    it "says the symptom looks like a slow database and is not" do
      config.http_server_command = "bundle exec puma --threads 1:16"

      expect(check(pool_size: 5).findings.first.detail)
        .to include("looks like a slow database and is not")
    end

    it "clears a pool that covers the thread ceiling" do
      config.http_server_command = "bundle exec puma --threads 1:5"

      expect(check(pool_size: 5).findings).to be_empty
    end

    # Taking the floor of `--threads 1:16` would clear it against a pool of 5. Under
    # load Puma grows to its ceiling, and the ceiling is what the pool has to cover.
    it "reads the MAXIMUM of a min:max thread pair, not the minimum" do
      config.http_server_command = "bundle exec puma --threads 1:16"

      expect(check(pool_size: 5).server_threads.value).to eq(16)
    end

    it "reads a bare thread count" do
      config.http_server_command = "bundle exec puma --threads 8"

      expect(check(pool_size: 20).server_threads.value).to eq(8)
    end

    # Each worker is its own process with its own pool, so workers must NOT be
    # multiplied into the comparison -- doing so would invent a finding for every
    # clustered Puma.
    it "does not multiply workers into the demand, since each has its own pool" do
      config.http_server_command = "bundle exec puma -w 4 --threads 1:4"

      result = check(pool_size: 5)

      expect(result.server_workers.value).to eq(4)
      expect(result.max_concurrent_demand.value).to eq(4)
      expect(result.findings).to be_empty
    end

    it "mentions the worker count in the finding, since it changes the total connections" do
      config.http_server_command = "bundle exec puma -w 3 --threads 1:16"

      expect(check(pool_size: 5).findings.first.detail).to include("3 worker processes")
    end

    it "treats an absent -w as single-mode rather than unknown" do
      config.http_server_command = "bundle exec puma --threads 1:4"

      expect(check(pool_size: 5).server_workers.value).to eq(1)
    end

    it "cannot read a thread count the command does not state, and says so" do
      config.http_server_command = "bundle exec puma"

      result = check(pool_size: 5)

      expect(result.server_threads).to be_unavailable
      expect(result.server_threads.reason).to include("does not specify --threads")
      expect(result.findings).to be_empty
    end
  end

  # THE SPLIT. performance-signals.md Part 4: under :in_process the static comparison
  # still works and the observed half does not. Two different Measurement results from
  # one check, never one blanket unavailable -- collapsing them throws away the half
  # that works in the DEFAULT execution mode.
  describe "under :in_process" do
    it "still performs the static comparison, because it needs no observation" do
      config.http_server_command = "bundle exec puma --threads 1:16"

      result = check(capability: in_process_capability, pool_size: 5)

      expect(result.server_threads).to be_available
      expect(result.findings.map(&:kind)).to eq([:pool_smaller_than_server_threads])
    end

    it "marks the observed half unavailable, with the reason capability gives" do
      config.http_server_command = "bundle exec puma --threads 1:16"

      result = check(capability: in_process_capability, pool_tracker: FakePoolTracker.new(peak_waiting: 9))

      expect(result.peak_waiting).to be_unavailable
      expect(result.peak_waiting.reason).to include("no server thread pool")
    end

    it "produces two different results from one check, rather than one blanket unavailable" do
      config.http_server_command = "bundle exec puma --threads 1:16"

      result = check(capability: in_process_capability, pool_size: 5)

      expect([result.server_threads.available?, result.peak_waiting.available?]).to eq([true, false])
    end
  end

  describe "the observed half" do
    it "reports the peaks when a real thread pool was watched" do
      config.http_server_command = "bundle exec puma --threads 1:4"
      tracker = FakePoolTracker.new(peak_busy: 4, peak_waiting: 2)

      result = check(capability: capability_with_pool_observation, pool_tracker: tracker, pool_size: 5)

      expect(result.peak_busy.value).to eq(4)
      expect(result.peak_waiting.value).to eq(2)
    end

    it "cites observed waiting in the finding when there was some" do
      config.http_server_command = "bundle exec puma --threads 1:16"
      tracker = FakePoolTracker.new(peak_waiting: 7)

      expect(check(capability: capability_with_pool_observation, pool_tracker: tracker, pool_size: 5)
        .findings.first.detail).to include("This run observed it: 7 thread(s) waiting")
    end

    # A latent misconfiguration alongside "no contention seen" reads as a contradiction
    # unless the report says why both are true.
    it "says a quiet run does not clear the misconfiguration" do
      config.http_server_command = "bundle exec puma --threads 1:16"
      tracker = FakePoolTracker.new(peak_waiting: 0)

      expect(check(capability: capability_with_pool_observation, pool_tracker: tracker, pool_size: 5)
        .findings.first.detail).to include("does not clear it")
    end

    it "is unavailable against a remote target, where there is no pool to see" do
      config.http_server_command = "bundle exec puma --threads 1:16"

      result = check(capability: external_capability, pool_tracker: FakePoolTracker.new(peak_waiting: 3))

      expect(result.peak_waiting).to be_unavailable
    end
  end

  describe "with no database connection" do
    it "cannot compare against a pool it cannot read, and says so rather than guessing" do
      config.http_server_command = "bundle exec puma --threads 1:16"
      result = described_class.new(config: config, capability: http_capability,
                                   pool_provider: -> { nil }).check

      expect(result.pool_size).to be_unavailable
      expect(result.findings).to be_empty
    end
  end

  describe "when disabled" do
    it "reports nothing rather than a misconfiguration it was told not to look for" do
      config.check_pool_vs_server_threads = false
      config.http_server_command = "bundle exec puma --threads 1:16"

      result = check(pool_size: 5)

      expect(result.findings).to be_empty
      expect(result.pool_size.reason).to include("check_pool_vs_server_threads is disabled")
    end
  end
end
