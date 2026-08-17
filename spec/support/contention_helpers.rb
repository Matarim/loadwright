# frozen_string_literal: true

module ContentionHelpers
  # A poller whose health answers are scripted, so the ladder can be walked
  # deterministically. The real poller's own behaviour — the out-of-pool connection,
  # the adapter probes — is tested separately against a real database.
  #
  # Expressed as "contended, and recovers after N polls" rather than as a list of
  # samples, because the guard polls a variable number of times per escalation and a
  # positional list makes every spec depend on that count.
  class ScriptedPoller
    attr_reader :poll_count, :registered

    def initialize(contended: false, blocker: :ours, recovers_after: nil, target_alive: nil,
                   degraded_reason: nil)
      @contended = contended
      @blocker = blocker
      @recovers_after = recovers_after
      @target_alive = target_alive
      @degraded_reason = degraded_reason
      @poll_count = 0
      @registered = false
      @latest = nil
    end

    def sample
      @poll_count += 1
      @latest = build(contended_now?)
    end

    def latest = @latest || build(@contended)

    def register_our_sessions!
      @registered = true
      self
    end

    def start! = self
    def stop! = self
    def to_h = { scripted: true, polls: @poll_count }

    private

    def contended_now?
      return @contended if @recovers_after.nil?

      @poll_count <= @recovers_after && @contended
    end

    def build(contended)
      sessions =
        case @blocker
        when :ours then [{ pid: 1, ours: true }]
        when :external then [{ pid: 2, ours: false }]
        else []
        end

      Loadwright::Engine::HealthPoller::Sample.new(
        at: Time.now,
        adapter: "PostgreSQL",
        healthy: !contended,
        lock_waits: contended ? 1 : 0,
        ungranted_locks: contended ? 1 : 0,
        pool_size: 5,
        pool_busy: contended ? 5 : 1,
        pool_waiting: contended ? 3 : 0,
        blocking_sessions: contended ? sessions : [],
        target_alive: @target_alive,
        degraded_reason: @degraded_reason
      )
    end
  end

  def health_sample(**options) = ScriptedPoller.new(**options).latest

  # A guard with no real sleeping, so ladder specs run in milliseconds rather than in
  # the tens of seconds the real backoff series takes. Returns [guard, poller, slept].
  def build_guard_with(config:, stdout: nil, **poller_options)
    slept = []
    poller = ScriptedPoller.new(**poller_options)
    guard = Loadwright::Engine::ResourceGuard.new(
      config: config,
      poller: poller,
      stdout: stdout || StringIO.new,
      sleeper: ->(seconds) { slept << seconds }
    )

    [guard, poller, slept]
  end

  # Tier 1 exception classes, defined as real constants under the ActiveRecord
  # namespace so the guard's by-name resolution is exercised exactly as it would be
  # in a host app.
  def stub_active_record_errors!
    return if defined?(::ActiveRecord::LockWaitTimeout)

    base = Class.new(StandardError)
    stub_const("ActiveRecord::StatementInvalid", Class.new(base))
    %w[LockWaitTimeout Deadlocked StatementTimeout QueryCanceled].each do |name|
      stub_const("ActiveRecord::#{name}", Class.new(ActiveRecord::StatementInvalid))
    end
    stub_const("ActiveRecord::ConnectionTimeoutError", Class.new(base))
  end
end

RSpec.configure { |c| c.include ContentionHelpers }
