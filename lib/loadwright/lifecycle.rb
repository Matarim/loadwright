# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  # Single teardown registry with one SIGINT/SIGTERM trap installed at the CLI
  # level. ensure blocks do not run on signals, and two subsystems trapping the
  # same signal races cleanup against itself, so the server manager and the
  # seeder register here instead of trapping independently.
  #
  # Specified in CLAUDE.md corollary 6.
  #
  # THE SIGNAL-HANDLER CONSTRAINT, because it shapes everything below.
  #
  # Very little is safe to do inside a Ruby trap handler. Acquiring a Mutex
  # raises ThreadError ("can't be called from trap context"), and much of the
  # stdlib — including Queue, Logger, and anything that opens a file — takes one
  # somewhere. A handler that does the actual teardown work therefore looks fine
  # in a unit test and deadlocks or crashes for real, at exactly the moment the
  # user is trying to stop a run that is holding 200k seeded rows.
  #
  # So the handler does only two things, both safe: assign an instance variable,
  # and write one byte to a pipe. A watcher thread started by #trap! blocks on
  # the read end, and does the real work as an ordinary thread where mutexes,
  # database connections, and file writes are all legal.
  class Lifecycle
    # Registered teardown work, run LIFO. `critical` callbacks run even when an
    # earlier one raised; a booted Puma process and 200k seeded rows must both
    # be cleaned up regardless of which cleanup failed first.
    Hook = Struct.new(:name, :callback, :critical, keyword_init: true)

    TeardownFailure = Struct.new(:name, :error, keyword_init: true)

    SIGNALS = %w[INT TERM].freeze

    # Conventional shell exit status for "terminated by SIGINT".
    INTERRUPT_EXIT_STATUS = 130

    attr_reader :teardown_failures

    def initialize(stderr: $stderr)
      @stderr = stderr
      @hooks = []
      @mutex = Mutex.new
      @teardown_ran = false
      @teardown_failures = []
      @interrupted = false
      @signal_name = nil
      @trapped = false
      @previous_handlers = {}
      @on_interrupt = nil
      @reader = nil
      @writer = nil
      @watcher = nil
    end

    # Registers teardown work. Returns a token that can be passed to #unregister
    # for work whose object goes away before the run ends (a server torn down
    # normally should not be torn down again at exit).
    def register(name, critical: false, &callback)
      raise ArgumentError, "a teardown hook requires a callback" unless callback

      hook = Hook.new(name: name.to_s, callback: callback, critical: critical)
      @mutex.synchronize { @hooks << hook }
      hook
    end

    def unregister(hook)
      @mutex.synchronize { @hooks.delete(hook) }
      nil
    end

    def registered_names
      @mutex.synchronize { @hooks.map(&:name) }
    end

    # Installs the single process-wide trap. `on_interrupt` is where the partial
    # report gets written; it runs BEFORE teardown, because teardown deletes the
    # seeded rows and tears down the server whose state the report describes.
    def trap!(exit_on_signal: true, &on_interrupt)
      raise ConfigurationError, "Lifecycle#trap! called twice; there is one trap per process" if @trapped

      @on_interrupt = on_interrupt
      @reader, @writer = IO.pipe
      @trapped = true
      start_watcher(exit_on_signal: exit_on_signal)

      SIGNALS.each do |signal|
        @previous_handlers[signal] = Signal.trap(signal) do
          # TRAP CONTEXT. Ivar assignment and a non-blocking pipe write only —
          # see the class comment. No mutex, no I/O object creation, no logging.
          @interrupted = true
          @signal_name ||= signal
          begin
            @writer.write_nonblock(".")
          rescue IO::WaitWritable, Errno::EPIPE, IOError
            # The watcher is already awake, or the pipe is gone because teardown
            # already completed. Either way there is nothing further to signal.
            nil
          end
        end
      end

      self
    end

    # Restores whatever handlers were in place before #trap!. Exists for the
    # gem's own suite: a leaked trap makes an unrelated later example
    # uninterruptible.
    def untrap!
      return self unless @trapped

      @previous_handlers.each { |signal, handler| Signal.trap(signal, handler || "DEFAULT") }
      @previous_handlers.clear
      @trapped = false
      @watcher&.kill
      @watcher = nil
      close_pipe
      self
    end

    # Polled by the load engine between requests. The engine stops issuing
    # requests and unwinds normally rather than being torn out from under
    # itself mid-request.
    def interrupted? = @interrupted

    def signal_name = @signal_name

    # Raises Interrupted if a signal has arrived, so the engine's normal unwind
    # (and therefore its normal ensure blocks) does the work.
    def check_interrupt!
      return false unless @interrupted

      raise Interrupted, "run interrupted by SIG#{@signal_name || 'INT'}"
    end

    # Runs every hook LIFO, exactly once per Lifecycle. Non-critical hooks stop
    # at the first failure of a *later* hook only in the sense that each
    # failure is recorded and the rest still run — nothing is skipped because
    # something else broke.
    #
    # Never raises. Teardown failures are recorded in #teardown_failures and
    # surfaced in report metadata; raising here would mask the original error
    # that triggered the unwind.
    def run_teardown!
      hooks = @mutex.synchronize do
        return @teardown_failures if @teardown_ran

        @teardown_ran = true
        @hooks.reverse
      end

      hooks.each do |hook|
        hook.callback.call
      rescue StandardError, ScriptError => e
        @teardown_failures << TeardownFailure.new(name: hook.name, error: e)
        @stderr.puts "loadwright: teardown hook #{hook.name.inspect} failed: #{e.class}: #{e.message}"
      end

      @teardown_failures
    end

    def teardown_ran? = @mutex.synchronize { @teardown_ran }

    def to_h
      {
        interrupted: interrupted?,
        signal: signal_name,
        teardown_ran: teardown_ran?,
        teardown_failures: @teardown_failures.map { |f| { hook: f.name, error: "#{f.error.class}: #{f.error.message}" } }
      }
    end

    private

    def start_watcher(exit_on_signal:)
      reader = @reader
      @watcher = Thread.new do
        # Blocks until the trap handler writes, or until the pipe is closed by
        # untrap! at the end of a normal run.
        reader.read(1)

        next unless @interrupted

        safely("interrupt callback") { @on_interrupt&.call(@signal_name) }
        run_teardown!
        exit!(INTERRUPT_EXIT_STATUS) if exit_on_signal
      rescue IOError
        # Pipe closed by untrap! on the normal path. Nothing to do.
        nil
      end
      @watcher.name = "loadwright-signal-watcher"
      @watcher.abort_on_exception = false
    end

    def safely(label)
      yield
    rescue StandardError => e
      @teardown_failures << TeardownFailure.new(name: label, error: e)
      @stderr.puts "loadwright: #{label} failed: #{e.class}: #{e.message}"
    end

    def close_pipe
      @writer&.close
      @reader&.close
    rescue IOError
      nil
    ensure
      @writer = nil
      @reader = nil
    end
  end
end
