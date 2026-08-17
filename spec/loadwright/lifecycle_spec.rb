# frozen_string_literal: true

RSpec.describe Loadwright::Lifecycle do
  subject(:lifecycle) { described_class.new(stderr: stderr) }

  let(:stderr) { StringIO.new }

  describe "#register" do
    it "requires a callback" do
      expect { lifecycle.register("no block") }.to raise_error(ArgumentError, /requires a callback/)
    end

    it "records the hook by name" do
      lifecycle.register("seed cleanup") { nil }
      lifecycle.register("server teardown") { nil }

      expect(lifecycle.registered_names).to eq(["seed cleanup", "server teardown"])
    end
  end

  describe "#unregister" do
    it "removes a hook whose work already happened on the normal path" do
      hook = lifecycle.register("server teardown") { raise "should not run" }
      lifecycle.unregister(hook)

      expect { lifecycle.run_teardown! }.not_to raise_error
      expect(lifecycle.teardown_failures).to be_empty
    end
  end

  describe "#run_teardown!" do
    it "runs hooks LIFO, so the thing registered last is undone first" do
      order = []
      lifecycle.register("seeded rows") { order << :rows }
      lifecycle.register("server") { order << :server }

      lifecycle.run_teardown!

      expect(order).to eq(%i[server rows])
    end

    it "runs every remaining hook even when one raises" do
      ran = []
      lifecycle.register("seeded rows") { ran << :rows }
      lifecycle.register("server") { raise "puma would not die" }
      lifecycle.register("query subscriber") { ran << :subscriber }

      lifecycle.run_teardown!

      expect(ran).to eq(%i[subscriber rows])
    end

    # Teardown runs while something else is already unwinding. Raising here
    # would replace the original cause with a cleanup error.
    it "never raises, recording the failure instead" do
      lifecycle.register("server") { raise ArgumentError, "boom" }

      expect { lifecycle.run_teardown! }.not_to raise_error

      failure = lifecycle.teardown_failures.first
      expect(failure.name).to eq("server")
      expect(failure.error).to be_a(ArgumentError)
      expect(stderr.string).to include("teardown hook \"server\" failed")
    end

    it "runs exactly once, so the normal ensure path and an at_exit cannot double-delete" do
      calls = 0
      lifecycle.register("seeded rows") { calls += 1 }

      3.times { lifecycle.run_teardown! }

      expect(calls).to eq(1)
      expect(lifecycle).to be_teardown_ran
    end
  end

  describe "#check_interrupt!" do
    it "is a no-op before any signal" do
      expect(lifecycle.check_interrupt!).to be(false)
    end

    it "raises Interrupted once a signal has been seen, so the normal unwind runs" do
      lifecycle.instance_variable_set(:@interrupted, true)
      lifecycle.instance_variable_set(:@signal_name, "TERM")

      expect { lifecycle.check_interrupt! }.to raise_error(Loadwright::Interrupted, /SIGTERM/)
    end
  end

  describe "#trap!" do
    after { lifecycle.untrap! }

    it "refuses a second trap, because there is one trap per process" do
      lifecycle.trap!(exit_on_signal: false)

      expect { lifecycle.trap!(exit_on_signal: false) }
        .to raise_error(Loadwright::ConfigurationError, /one trap per process/)
    end

    it "installs handlers for both INT and TERM" do
      lifecycle.trap!(exit_on_signal: false)

      described_class::SIGNALS.each do |signal|
        previous = Signal.trap(signal, "DEFAULT")
        expect(previous).to be_a(Proc), "expected SIG#{signal} to be trapped"
        Signal.trap(signal, previous)
      end
    end

    # The behaviour that matters: a real signal must reach teardown. This sends
    # an actual SIGTERM to this process rather than calling the handler
    # directly, because "would this work under a real signal" is the whole
    # question — a handler that takes a mutex passes a direct-call test and
    # raises ThreadError for real.
    it "runs the interrupt callback and then teardown on a real signal" do
      order = Queue.new
      lifecycle.register("seeded rows") { order << :teardown }
      lifecycle.trap!(exit_on_signal: false) { |signal| order << [:report, signal] }

      Process.kill("TERM", Process.pid)

      # The watcher is a separate thread; wait for it rather than sleeping blind.
      first = order.pop
      second = order.pop

      expect(first).to eq([:report, "TERM"])
      expect(second).to eq(:teardown)
      expect(lifecycle).to be_interrupted
      expect(lifecycle.signal_name).to eq("TERM")
    end

    it "leaves the run interruptible from the engine's point of view" do
      lifecycle.trap!(exit_on_signal: false)

      Process.kill("TERM", Process.pid)
      Thread.pass until lifecycle.interrupted?

      expect { lifecycle.check_interrupt! }.to raise_error(Loadwright::Interrupted)
    end
  end

  describe "#untrap!" do
    it "restores the previous handlers so an unrelated later run is still interruptible" do
      sentinel = proc { nil }
      original = Signal.trap("INT", sentinel)

      lifecycle.trap!(exit_on_signal: false)
      lifecycle.untrap!

      expect(Signal.trap("INT", original)).to be(sentinel)
    end

    it "is safe to call without a trap installed" do
      expect { lifecycle.untrap! }.not_to raise_error
    end
  end

  describe "#to_h" do
    it "reports teardown provenance for the run metadata section" do
      lifecycle.register("server") { raise "boom" }
      lifecycle.run_teardown!

      expect(lifecycle.to_h).to include(
        interrupted: false,
        teardown_ran: true,
        teardown_failures: [{ hook: "server", error: "RuntimeError: boom" }]
      )
    end
  end
end
