# frozen_string_literal: true

require "English"
require "open3"
require "securerandom"
require "tmpdir"
require "net/http"
require "socket"
require "uri"
require "loadwright/errors"
require "loadwright/execution/identity_endpoint"

module Loadwright
  module Execution
    # Boots the app under test for :http mode, polls until it is healthy, and tears
    # it down.
    #
    # Teardown is registered with Lifecycle rather than trapped here. That is the
    # whole reason this class does not call Signal.trap: two subsystems trapping
    # the same signal races cleanup against itself, and an orphaned Puma process
    # holding a port is the most annoying thing a load-test tool can leave behind.
    # The seeder registers with the same registry, and the CLI installs the one
    # trap.
    class ServerManager
      DEFAULT_HOST = "127.0.0.1"

      # The child is told WHERE the secret is, never what it is.
      #
      # An environment variable carrying the secret itself is readable by any local
      # user through `ps` on most systems, and environment blocks land in crash dumps,
      # process listings, and anything that logs a spawn. The secret guards an endpoint
      # that serves SQL and call sites from the app under test, so that is a real
      # exposure and not a theoretical one — a per-run lifetime shortens the window but
      # does not close it.
      #
      # A mode-0600 file closes it: only the running user can read it, nothing prints
      # its contents, and the path is uninteresting on its own. Chosen over handing the
      # secret over stdin because the child is an arbitrary `http_server_command` — Puma
      # does not read a secret from stdin, and a scheme that depends on the server
      # cooperating would break the moment someone configures a different one.
      SECRET_FILE_VARIABLE = "LOADWRIGHT_COLLECTOR_SECRET_FILE"

      # The run this secret belongs to. Travels beside the path so the reader can
      # reject a secret written by a DIFFERENT run — see read_secret_file.
      SECRET_RUN_ID_VARIABLE = "LOADWRIGHT_COLLECTOR_RUN_ID"

      # Written into the per-run directory beside the secret, so a run that is
      # SIGKILLed leaves behind enough to identify and clean up its own server.
      #
      # WHY THIS EXISTS AT ALL. SIGKILL is not trappable, and neither is a lost power
      # supply or a laptop that sleeps until the terminal is gone. In every one of
      # those cases Lifecycle's teardown never runs, and a Puma keeps holding the
      # developer's development database open. That is a diagnostic tool leaving the
      # environment worse than it found it — the category of harm the whole safety
      # design exists to avoid — and it is not hypothetical: three of them accumulated
      # during this gem's own development and hung an unrelated test run.
      PIDFILE_NAME = "server.pid"

      RUN_DIR_PREFIX = "loadwright-run-"

      # The pidfile is keyed rather than positional, so a field can be added without
      # a later reader mistaking one line for another. That matters more here than
      # anywhere else in the gem: a misread line is a PID we might signal.
      #
      # A file that does not parse into at least a `server` line is not a record at
      # all — read_pidfile returns nil and the directory is treated as litter, which
      # is the same fail-toward-not-killing default as an unverifiable start time.
      PIDFILE_KEYS = %w[host server harness url].freeze

      # PID alone is not an identity. PIDs are recycled, and on a busy machine the
      # number in a day-old pidfile may belong to something a developer cares about.
      # The process start time is what makes it real: a recycled PID has a different
      # start time, so a stale record is self-evidently stale rather than merely
      # probably stale.
      # A start time we could not read. Recorded rather than omitted so the pidfile
      # stays parseable, and can never match a real one — so a record we cannot verify
      # fails toward NOT killing anything.
      UNKNOWN_START = "unknown"

      ProcessIdentity = Struct.new(:pid, :started_at, keyword_init: true) do
        def to_line = "#{pid} #{started_at || UNKNOWN_START}"

        def self.from_line(line)
          pid, started_at = line.to_s.strip.split(" ", 2)
          pid = Integer(pid, exception: false)
          return nil if pid.nil? || started_at.to_s.empty?

          new(pid: pid, started_at: started_at)
        end

        # Running AND the same process we recorded. Never one without the other, and
        # never on an unverifiable record.
        #
        # A ZOMBIE COUNTS AS NOT RUNNING. It still appears in `ps` — which is how the
        # first version of this got it wrong — but it holds no database connection and
        # no port, so it is nothing to kill and its directory is litter.
        def current?
          return false if pid.nil?
          # Belt and braces, and deliberately so: the comparison at the end would
          # already return false for UNKNOWN_START, since a real start time can never
          # equal that literal. Kept because it states the intent at the top of the
          # method rather than leaving it to be derived. The mutation audit reports no
          # behaviour change for removing it, which is correct — do not add a mutation
          # for this line expecting it to bite.
          return false if started_at.to_s == UNKNOWN_START
          return false unless ServerManager.process_running?(pid)

          ServerManager.process_start_time(pid) == started_at
        end
      end

      attr_reader :port, :host, :pid, :base_url, :run_dir

      # WHICH MACHINE WROTE THE RECORD.
      #
      # Dir.mktmpdir is local in the normal case, but TMPDIR pointed at a shared or
      # network volume would let two machines see each other's run directories. A PID
      # plus a start time is unique enough WITHIN one process table and not across
      # two: another host's pid 4242, started at a time that happens to match ours,
      # names one of our processes on inspection and something entirely unrelated in
      # reality.
      #
      # Recorded here and checked during the scan, on the same principle as an
      # unreadable start time: a record we cannot attribute to this machine is not
      # ours to act on, so we neither kill nor delete it.
      def self.current_hostname
        @current_hostname ||= Socket.gethostname.to_s.strip
      rescue StandardError
        # No hostname means no record can be attributed to this machine, so nothing is
        # reaped. Litter accumulates; nothing of anyone's gets killed.
        ""
      end

      # Absolute start time, as the OS reports it. Compared as an opaque string: the
      # only property needed is that it differs when the PID has been recycled.
      def self.process_start_time(pid)
        return nil if pid.nil?

        out, _err, status = Open3.capture3("ps", "-o", "lstart=", "-p", pid.to_s)
        return nil unless status.success?

        stripped = out.strip
        stripped.empty? ? nil : stripped
      rescue StandardError
        nil
      end

      # Running, as distinct from merely present in the process table. A zombie has
      # exited and is waiting to be reaped by its parent: it holds no port and no
      # database connection, so for every purpose here it is gone.
      def self.process_running?(pid)
        return false if pid.nil?

        out, _err, status = Open3.capture3("ps", "-o", "state=", "-p", pid.to_s)
        return false unless status.success?

        state = out.strip
        !state.empty? && !state.start_with?("Z")
      rescue StandardError
        false
      end

      # Reaps servers left behind by runs that could not clean up after themselves.
      # Called at the start of every :http run, before anything is booted.
      #
      # THE RULES, and each exists because of a way this could do harm:
      #
      #   * Never kill on PID alone. A recycled PID may belong to something the
      #     developer cares about. Reaping requires the recorded start time to match.
      #   * Never touch a record written by ANOTHER MACHINE. A PID plus start time is
      #     an identity within one process table, not across two, so a foreign record
      #     read against our process table names an unrelated process. Neither killed
      #     nor deleted — we have positive evidence it is not ours.
      #   * Never kill a server whose HARNESS is still alive. That is a concurrent
      #     Loadwright run, not an orphan, and killing its server would break it.
      #   * A directory whose server is already gone is just litter: remove it.
      #
      # Same inertness principle as the secret file: a leftover should be
      # self-evidently dead and cleanable, not merely unlikely to matter.
      def self.reap_orphans!(stdout: $stdout, tmpdir: Dir.tmpdir)
        reaped = []

        Dir.glob(File.join(tmpdir, "#{RUN_DIR_PREFIX}*")).each do |dir|
          record = read_pidfile(dir)

          # No readable pidfile: nothing identifiable to kill, so the directory is
          # litter. (A run still writing one is a race we lose harmlessly — it is
          # removed and the live run keeps working from its own handles.)
          next remove_run_dir(dir) if record.nil?

          # Written by a different machine, visible only because TMPDIR is shared.
          # Its PIDs describe a process table that is not ours, so there is nothing
          # here we can judge -- and a record we cannot attribute to this machine is
          # not ours to delete either.
          next unless record[:host] == current_hostname

          server, harness = record.values_at(:server, :harness)

          unless server&.current?
            # Either exited, or the PID was recycled and now belongs to someone else.
            # Either way there is nothing of ours to kill.
            remove_run_dir(dir)
            next
          end

          if harness&.current?
            # A run is in progress. Not an orphan.
            next
          end

          stdout.puts "loadwright: reaping an orphaned server (pid #{server.pid}) left by a run that " \
                      "could not clean up — it was still holding your database open"
          terminate_pid(server.pid)
          reaped << server.pid
          remove_run_dir(dir)
        end

        reaped
      end

      def self.read_pidfile(dir)
        path = File.join(dir, PIDFILE_NAME)
        return nil unless File.file?(path)

        fields = File.readlines(path).each_with_object({}) do |line, out|
          key, value = line.strip.split(" ", 2)
          out[key] = value if PIDFILE_KEYS.include?(key)
        end

        server = ProcessIdentity.from_line(fields["server"])
        return nil if server.nil?

        {
          host: fields["host"],
          server: server,
          harness: ProcessIdentity.from_line(fields["harness"]),
          url: fields["url"]
        }
      rescue StandardError
        nil
      end

      def self.write_pidfile_contents(host:, server:, harness:, url:)
        [
          "host #{host}",
          "server #{server.to_line}",
          "harness #{harness.to_line}",
          "url #{url}"
        ].join("\n") + "\n"
      end

      def self.remove_run_dir(dir)
        require "fileutils"
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end

      # TERM the group, then KILL. Same escalation as #stop!, without the instance.
      def self.terminate_pid(pid)
        [-pid, pid].each do |target|
          Process.kill("TERM", target)
          break
        rescue Errno::ESRCH, Errno::EPERM
          next
        end

        20.times do
          return true unless process_running?(pid)

          sleep 0.1
        end

        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH, Errno::EPERM
          begin
            Process.kill("KILL", pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
        end
        true
      end

      # Read by the child's railtie. Refuses anything that is not a private regular
      # file: a world-readable secret file has already failed at its one job, and
      # proceeding would arm the endpoint while pretending the secret was protected.
      # ALSO REFUSES A SECRET FROM ANOTHER RUN. SIGKILL cannot be trapped, so a run
      # that is hard-killed leaves its directory behind however careful the teardown
      # is — the file outlives the run that owned it. Binding the secret to a run id
      # and checking it here makes a leftover INERT rather than merely unlikely to be
      # found: a later process that somehow points at it declines to arm, and says why.
      def self.read_secret_file(path, expected_run_id = nil)
        return nil if path.to_s.empty?
        return nil unless File.file?(path)

        mode = File.stat(path).mode & 0o777
        if mode & 0o077 != 0
          warn "loadwright: refusing to read the collector secret from #{path}: mode is " \
               "#{format('%<mode>04o', mode: mode)}, which is readable by other users"
          return nil
        end

        run_id, secret = File.read(path).split("\n", 2)
        run_id = run_id.to_s.strip
        secret = secret.to_s.strip
        return nil if secret.empty?

        if expected_run_id && run_id != expected_run_id.to_s
          warn "loadwright: refusing the collector secret at #{path}: it belongs to run " \
               "#{run_id.inspect}, not #{expected_run_id.to_s.inspect}. This is a leftover from a run " \
               "that was killed before it could clean up; it is inert and can be deleted."
          return nil
        end

        secret
      rescue StandardError => e
        warn "loadwright: could not read the collector secret file (#{e.class}); " \
             "the collector middleware will not be armed"
        nil
      end

      def initialize(config: Loadwright.configuration, lifecycle: nil, stdout: $stdout,
                     host: DEFAULT_HOST, collector_secret: nil)
        @config = config
        @lifecycle = lifecycle
        @stdout = stdout
        @host = host
        @collector_secret = collector_secret
        @pid = nil
        @port = nil
        @teardown_hook = nil
      end

      # True when Loadwright is pointing at a server it did not start. Capability
      # is unaffected by this — that is the collector's business — but provenance
      # is not: a report must name whether the target was booted here.
      def external_target? = !@config.http_target_url.to_s.strip.empty?

      def start!
        if external_target?
          @base_url = @config.http_target_url
          wait_for_health!
          return self
        end

        # Before booting anything: clean up after runs that could not clean up after
        # themselves. Doing it here rather than at exit is the point — the exit path is
        # exactly the one a SIGKILLed run never reached.
        self.class.reap_orphans!(stdout: @stdout)

        @port = allocate_port
        @base_url = "http://#{@host}:#{@port}"
        create_run_dir!
        spawn_server
        write_pidfile!
        register_teardown
        wait_for_health!
        self
      end

      def stop!
        return self if @pid.nil?

        pid = @pid
        @pid = nil

        # TERM, then wait, then KILL. Never anything cleverer: the point is that
        # the port is free and no process is left running, and escalating politely
        # is the only reliable way to get there.
        terminate(pid, "TERM")
        return self if reaped?(pid, timeout: 5)

        @stdout.puts "loadwright: server #{pid} did not exit on SIGTERM; sending SIGKILL"
        terminate(pid, "KILL")
        reaped?(pid, timeout: 2)
        self
      ensure
        remove_secret_file!
        @lifecycle&.unregister(@teardown_hook) if @teardown_hook
        @teardown_hook = nil
      end

      # Deliberately NOT Process.kill(0, pid): that returns true for a zombie — a
       # child that has exited but not been reaped — which is exactly the state a
      # server that dies during boot is in. The health loop would then wait out
      # the full http_boot_timeout and report a timeout instead of naming the real
      # cause, which is usually a missing database or a port already in use.
      def running?
        return false if @pid.nil?
        return false if @exit_status

        reaped = Process.waitpid(@pid, Process::WNOHANG)
        @exit_status = $CHILD_STATUS || true if reaped
        reaped.nil?
      rescue Errno::ECHILD, Errno::ESRCH
        @exit_status ||= true
        false
      end

      def exit_status = @exit_status

      # Used by the resource guard's Tier 2 poll. An unresponsive server under
      # :http is a Rung 5 global abort, not something to keep issuing requests
      # into — a failure mode :in_process cannot produce.
      def alive?
        return false unless external_target? || running?

        probe!
        true
      rescue StandardError
        false
      end

      def to_h
        {
          base_url: @base_url,
          booted_by_loadwright: !external_target?,
          pid: @pid,
          port: @port,
          collector_armed: !@collector_secret.nil?,
          run_dir: @run_dir
        }.compact
      end

      private

      def spawn_server
        command = @config.http_server_command || default_command
        env = { "PORT" => @port.to_s, "RAILS_ENV" => current_environment, "RACK_ENV" => current_environment }

        # The child arms its own collector middleware from this (see railtie.rb). The
        # PATH travels in the environment; the secret itself never does.
        if @collector_secret
          env[SECRET_FILE_VARIABLE] = write_secret_file!
          env[SECRET_RUN_ID_VARIABLE] = run_id
        end

        @stdout.puts "loadwright: booting #{command} on #{@base_url}"
        @pid = Process.spawn(env, command, out: :out, err: :err, pgroup: true)
      rescue StandardError => e
        raise ServerError, "could not boot the app under test with #{command.inspect}: #{e.class}: #{e.message}"
      end

      # Written 0600 inside a PER-RUN 0700 DIRECTORY, and removed by the Lifecycle
      # teardown that already tears down the server.
      #
      # The directory is not tidiness. Two things it buys:
      #
      #   * It closes a symlink race. Writing a predictable name into a shared,
      #     world-writable temp directory lets another local user pre-create that path
      #     as a symlink and have us write the secret wherever they point it.
      #     Dir.mktmpdir creates a fresh 0700 directory with a name we do not control,
      #     so there is nothing to pre-create and nothing to traverse.
      #
      #   * It bounds what a hard kill can leave behind. SIGKILL cannot be trapped, so
      #     teardown is not guaranteed to run and the directory can outlive the run. It
      #     is then one self-contained thing to find, and its contents are inert,
      #     because the secret carries the run id it belongs to.
      # One directory per run, holding everything that must not outlive it: the
      # collector secret and the pidfile. Created 0700 with a name we do not control,
      # which is also what closes the symlink race described above.
      def create_run_dir!
        return @run_dir if @run_dir

        require "tmpdir"
        require "fileutils"

        @run_dir = Dir.mktmpdir("#{RUN_DIR_PREFIX}#{run_id}-")
        FileUtils.chmod(0o700, @run_dir)
        @run_dir
      end

      # Server identity plus HARNESS identity. Both are needed: the server line says
      # what to kill, and the harness line is how a later run tells an orphan from a
      # concurrent run's healthy server.
      def write_pidfile!
        return if @run_dir.nil? || @pid.nil?

        server = ProcessIdentity.new(pid: @pid, started_at: self.class.process_start_time(@pid))
        harness = ProcessIdentity.new(pid: Process.pid, started_at: self.class.process_start_time(Process.pid))

        File.write(
          File.join(@run_dir, PIDFILE_NAME),
          self.class.write_pidfile_contents(
            host: self.class.current_hostname, server: server, harness: harness, url: @base_url
          )
        )
      rescue StandardError => e
        # Not fatal. It costs the orphan-reaping safety net for this run, which is worth
        # a warning and not worth refusing to run over.
        @stdout.puts "loadwright: could not write the server pidfile (#{e.class}); if this run is " \
                     "killed outright, the server may need stopping by hand"
      end

      def write_secret_file!
        create_run_dir!

        path = File.join(@run_dir, "collector-#{run_id}.secret")
        # Created 0600 by the open itself rather than chmodded afterwards: a file that
        # exists world-readable even briefly has already been readable.
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("#{run_id}\n#{@collector_secret}")
        end

        @secret_path = path
      end

      def remove_secret_file!
        return if @run_dir.nil?

        require "fileutils"
        FileUtils.remove_entry(@run_dir)
      rescue StandardError
        nil
      ensure
        @run_dir = nil
        @secret_path = nil
      end

      # Identifies this run, so a secret left behind by a killed run cannot arm a later
      # one. Derived once and stable for the object's life.
      def run_id
        @run_id ||= "#{Process.pid}-#{SecureRandom.hex(4)}"
      end

      def default_command = "bundle exec puma -p #{@port} -e #{current_environment} --threads 1:5"

      def current_environment
        return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env

        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      end

      # Bind to port 0, ask what we got, release it. Racy in principle; in practice
      # the alternative — a fixed port — collides with the app the developer
      # already has running on 3000, which is not a principle, it is Tuesday.
      def allocate_port
        server = TCPServer.new(@host, 0)
        server.addr[1]
      ensure
        server&.close
      end

      def wait_for_health!
        deadline = monotonic + @config.http_boot_timeout

        loop do
          if @pid && !running?
            raise ServerError,
                  "the app under test exited before becoming healthy (status: #{@exit_status.inspect}). Its " \
                  "output is above; the usual causes are a missing database, a failed migration, or a port " \
                  "already in use."
          end

          begin
            probe!
            @stdout.puts "loadwright: server healthy at #{@base_url}"
            return true
          rescue StandardError => e
            @last_health_error = e
          end

          if monotonic > deadline
            raise ServerError,
                  "the app under test at #{@base_url} did not become healthy within " \
                  "#{@config.http_boot_timeout}s (last error: #{@last_health_error&.class}: " \
                  "#{@last_health_error&.message})"
          end

          sleep 0.1
        end
      end

      # The identity endpoint is the health probe. It is mounted whenever the gem
      # is loaded, needs no secret, touches no database, and answering it proves
      # both that the process is up AND that it loads Loadwright — which is exactly
      # the pair of facts a boot check needs.
      def probe!
        uri = URI.join(@base_url, IdentityEndpoint::PATH)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: 1, read_timeout: 2) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end

        raise ServerError, "health probe returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response
      end

      def register_teardown
        @teardown_hook = @lifecycle&.register("app server (pid #{@pid})", critical: true) { stop! }
      end

      def terminate(pid, signal)
        # Negative pid signals the process group, so a `bundle exec` wrapper does
        # not leave the real server orphaned behind it.
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      def reaped?(pid, timeout:)
        deadline = monotonic + timeout

        while monotonic < deadline
          return true if Process.waitpid(pid, Process::WNOHANG)

          sleep 0.05
        end
        false
      rescue Errno::ECHILD
        true
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
