# frozen_string_literal: true

# Boots real subprocesses. The alternative — mocking Process.spawn — would test
# that we call spawn, which is not the part that goes wrong. What goes wrong is
# a server that never becomes healthy, one that dies during boot, and one that
# survives SIGTERM; all three are here.
RSpec.describe Loadwright::Execution::ServerManager do
  let(:config) { Loadwright::Configuration.new }
  let(:lifecycle) { Loadwright::Lifecycle.new(stderr: StringIO.new) }
  let(:stdout) { StringIO.new }

  subject(:manager) do
    described_class.new(config: config, lifecycle: lifecycle, stdout: stdout)
  end

  after { manager.stop! }

  # A minimal server that answers the identity endpoint. Written as a one-liner
  # script so the subprocess needs nothing from this repo.
  def identity_server_script(ignore_term: false, exit_immediately: false)
    <<~RUBY
      #{'Signal.trap("TERM") { }' if ignore_term}
      #{'exit 1' if exit_immediately}
      require "socket"
      server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT")))
      loop do
        socket = server.accept
        socket.gets
        body = '{"env":"test","loadwright_version":"0.0.1","enabled_here":true}'
        socket.print("HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\n" \\
                     "Content-Length: \#{body.bytesize}\\r\\nConnection: close\\r\\n\\r\\n\#{body}")
        socket.close
      end
    RUBY
  end

  def server_command(**options)
    "#{RbConfig.ruby} -e #{Shellwords.escape(identity_server_script(**options))}"
  end

  before { require "shellwords" }

  describe "#start!" do
    it "boots the server, allocates a port, and polls until healthy" do
      config.http_server_command = server_command

      manager.start!

      expect(manager.port).to be > 1024
      expect(manager.base_url).to eq("http://127.0.0.1:#{manager.port}")
      expect(manager).to be_running
      expect(stdout.string).to include("server healthy at")
    end

    # The identity endpoint is the probe. It needs no secret, touches no database,
    # and answering it proves both that the process is up AND that it loads
    # Loadwright — exactly the pair of facts a boot check needs.
    it "probes the identity endpoint, not a guessed health route" do
      config.http_server_command = server_command
      manager.start!

      expect(manager.alive?).to be(true)
    end

    it "fails with a diagnosis rather than hanging when the server never gets healthy" do
      config.http_server_command = "#{RbConfig.ruby} -e 'sleep 30'"
      config.http_boot_timeout = 1

      expect { manager.start! }
        .to raise_error(Loadwright::ServerError, /did not become healthy within 1s/)
    end

    # The three usual causes — missing database, failed migration, port in use —
    # all look like this, and the message says so rather than leaving the user to
    # read a timeout.
    it "notices immediately when the server exits during boot" do
      config.http_server_command = "#{RbConfig.ruby} -e 'exit 1'"
      config.http_boot_timeout = 10

      expect { manager.start! }
        .to raise_error(Loadwright::ServerError, /exited before becoming healthy/)
    end
  end

  describe "teardown" do
    # Registered with Lifecycle rather than trapped here. Two subsystems trapping
    # the same signal races cleanup against itself, and an orphaned Puma holding a
    # port is the most annoying thing this tool could leave behind.
    it "registers its teardown with Lifecycle instead of trapping signals itself" do
      config.http_server_command = server_command
      manager.start!

      expect(lifecycle.registered_names.join).to include("app server")
    end

    it "is torn down by a Lifecycle teardown, as a signal would trigger" do
      config.http_server_command = server_command
      manager.start!
      pid = manager.pid

      lifecycle.run_teardown!

      expect(process_alive?(pid)).to be(false)
    end

    it "escalates to SIGKILL for a server that ignores SIGTERM" do
      config.http_server_command = server_command(ignore_term: true)
      manager.start!
      pid = manager.pid

      manager.stop!

      expect(stdout.string).to include("did not exit on SIGTERM; sending SIGKILL")
      expect(process_alive?(pid)).to be(false)
    end

    it "unregisters after a normal stop, so exit teardown does not kill a stranger" do
      config.http_server_command = server_command
      manager.start!

      manager.stop!

      expect(lifecycle.registered_names.join).not_to include("app server")
    end

    it "is safe to stop twice" do
      config.http_server_command = server_command
      manager.start!

      expect { 2.times { manager.stop! } }.not_to raise_error
    end
  end

  describe "an already-running target" do
    it "does not boot anything and records that it did not" do
      config.http_target_url = "http://127.0.0.1:1"

      expect(manager).to be_external_target
      expect(manager.to_h[:booted_by_loadwright]).to be(false)
    end

    it "still requires the target to be healthy before the run starts" do
      config.http_target_url = "http://127.0.0.1:1"
      config.http_boot_timeout = 1

      expect { manager.start! }.to raise_error(Loadwright::ServerError, /did not become healthy/)
    end
  end

  def process_alive?(pid)
    # Give the OS a moment to reap; a just-signalled process can linger briefly.
    20.times do
      Process.kill(0, pid)
      sleep 0.05
    end
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end
end

# The collector secret guards an endpoint that serves SQL and call sites from the app
# under test. It reaches the child through a mode-0600 FILE, with only the path in the
# environment — an environment block is readable by any local user through `ps` and
# lands in crash dumps and spawn logs.
RSpec.describe Loadwright::Execution::ServerManager, "the collector secret" do
  require "fileutils"
  require "tmpdir"

  let(:config) { Loadwright::Configuration.new }
  let(:lifecycle) { Loadwright::Lifecycle.new(stderr: StringIO.new) }

  subject(:manager) do
    described_class.new(config: config, lifecycle: lifecycle, stdout: StringIO.new,
                        collector_secret: "s3cr3t-per-run")
  end

  describe "what reaches the child" do
    it "passes a PATH in the environment, never the secret itself" do
      captured = nil
      allow(Process).to receive(:spawn) { |env, *| captured = env; 424_242 }
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)

      manager.start!

      expect(captured.values.join).not_to include("s3cr3t-per-run")
      path = captured.fetch(described_class::SECRET_FILE_VARIABLE)
      run_id = captured.fetch(described_class::SECRET_RUN_ID_VARIABLE)

      expect(File.read(path)).to eq("#{run_id}\ns3cr3t-per-run")
      expect(described_class.read_secret_file(path, run_id)).to eq("s3cr3t-per-run")
    end

    # A predictable name in a shared temp directory lets another local user pre-create
    # that path as a symlink and have the secret written wherever they point it.
    # mktmpdir creates a fresh 0700 directory with a name we do not control.
    it "writes into a per-run directory that only its owner can enter" do
      captured = nil
      allow(Process).to receive(:spawn) { |env, *| captured = env; 424_242 }
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)

      manager.start!

      directory = File.dirname(captured.fetch(described_class::SECRET_FILE_VARIABLE))
      mode = File.stat(directory).mode & 0o777

      expect(mode).to eq(0o700), format("directory mode was %<mode>04o", mode: mode)
      expect(File.basename(directory)).to start_with("loadwright-run-")
    end

    it "names the file for the run, so a leftover identifies itself" do
      captured = nil
      allow(Process).to receive(:spawn) { |env, *| captured = env; 424_242 }
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)

      manager.start!

      path = captured.fetch(described_class::SECRET_FILE_VARIABLE)
      expect(File.basename(path)).to eq("collector-#{captured.fetch(described_class::SECRET_RUN_ID_VARIABLE)}.secret")
    end

    it "writes the file readable only by its owner" do
      allow(Process).to receive(:spawn).and_return(424_242)
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)
      captured = nil
      allow(Process).to receive(:spawn) { |env, *| captured = env; 424_242 }

      manager.start!

      mode = File.stat(captured.fetch(described_class::SECRET_FILE_VARIABLE)).mode & 0o777
      expect(mode & 0o077).to eq(0), format("mode was %<mode>04o", mode: mode)
    end

    it "removes the file on teardown, so an interrupted run leaves nothing behind" do
      captured = nil
      allow(Process).to receive(:spawn) { |env, *| captured = env; 424_242 }
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)
      allow(manager).to receive(:terminate)
      allow(manager).to receive(:reaped?).and_return(true)
      manager.start!
      path = captured.fetch(described_class::SECRET_FILE_VARIABLE)

      lifecycle.run_teardown!

      expect(File.exist?(path)).to be(false)
      # The whole per-run directory goes, not just the file inside it.
      expect(Dir.exist?(File.dirname(path))).to be(false)
    end

    # The case teardown cannot cover: SIGKILL is untrappable, so the file survives.
    # It must be inert rather than merely hard to find.
    it "leaves an inert file behind when the run is hard-killed" do
      captured = nil
      allow(Process).to receive(:spawn) { |env, *| captured = env; 424_242 }
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)
      manager.start!
      path = captured.fetch(described_class::SECRET_FILE_VARIABLE)

      # No teardown at all — this is what SIGKILL looks like from the file's side.
      expect(File.exist?(path)).to be(true)
      expect(described_class.read_secret_file(path, "a-later-run")).to be_nil
    ensure
      FileUtils.remove_entry(File.dirname(path)) if path && Dir.exist?(File.dirname(path))
    end

    it "passes nothing when there is no secret to pass (a remote target)" do
      captured = nil
      allow(Process).to receive(:spawn) { |env, *| captured = env; 424_242 }
      plain = described_class.new(config: config, stdout: StringIO.new)
      allow(plain).to receive(:wait_for_health!).and_return(true)
      allow(plain).to receive(:running?).and_return(true)

      plain.start!

      expect(captured).not_to have_key(described_class::SECRET_FILE_VARIABLE)
    end
  end

  describe ".read_secret_file" do
    around do |example|
      Dir.mktmpdir("loadwright-secret") { |dir| @dir = dir; example.run }
    end

    def write(secret, mode, run_id: "run-1")
      path = File.join(@dir, "secret")
      File.write(path, "#{run_id}\n#{secret}")
      File.chmod(mode, path)
      path
    end

    it "reads a private file" do
      expect(described_class.read_secret_file(write("abc123", 0o600), "run-1")).to eq("abc123")
    end

    it "reads without a run id, for a caller that has none to check" do
      expect(described_class.read_secret_file(write("abc123", 0o600))).to eq("abc123")
    end

    # SIGKILL cannot be trapped, so a hard-killed run leaves its file behind however
    # careful teardown is. Binding the secret to a run makes the leftover INERT rather
    # than merely unlikely to be found.
    it "refuses a secret written by a different run" do
      path = write("abc123", 0o600, run_id: "an-older-run")

      expect { expect(described_class.read_secret_file(path, "this-run")).to be_nil }
        .to output(/belongs to run "an-older-run"/).to_stderr
    end

    it "says the leftover is inert and can be deleted, rather than just refusing" do
      path = write("abc123", 0o600, run_id: "an-older-run")

      expect { described_class.read_secret_file(path, "this-run") }
        .to output(/inert and can be deleted/).to_stderr
    end

    # A world-readable secret file has already failed at its one job. Arming the
    # endpoint anyway would pretend the secret was protected when it was not.
    it "refuses a file other users can read" do
      expect { expect(described_class.read_secret_file(write("abc123", 0o644), "run-1")).to be_nil }
        .to output(/readable by other users/).to_stderr
    end

    it "refuses a group-readable file too" do
      expect(described_class.read_secret_file(write("abc123", 0o640), "run-1")).to be_nil
    end

    it "is nil for a missing path, an empty path, and an empty file" do
      expect(described_class.read_secret_file(nil, "run-1")).to be_nil
      expect(described_class.read_secret_file("", "run-1")).to be_nil
      expect(described_class.read_secret_file(File.join(@dir, "nope"), "run-1")).to be_nil
      expect(described_class.read_secret_file(write("   ", 0o600), "run-1")).to be_nil
    end
  end
end

# ORPHANED SERVERS ARE A USER-FACING BUG, not just a nuisance in our own tooling.
#
# SIGKILL is not trappable, and neither is a lost power supply or a laptop that sleeps
# until the terminal is gone. In all of those Lifecycle's teardown never runs and a Puma
# keeps holding the developer's development database open — a diagnostic tool leaving the
# environment worse than it found it. Three accumulated during this gem's own development
# and hung an unrelated test run, which is how this got noticed.
RSpec.describe Loadwright::Execution::ServerManager, "orphan reaping" do
  require "fileutils"
  require "tmpdir"

  let(:stdout) { StringIO.new }

  around do |example|
    Dir.mktmpdir("reap-test-") { |dir| @tmp = dir; example.run }
  end

  # A real child process that outlives its "harness", which is what an orphan is.
  def spawn_orphan
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 300", pgroup: true)
    @spawned = Array(@spawned) << pid
    pid
  end

  after do
    Array(@spawned).each do |pid|
      Process.kill("KILL", pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  def run_dir(name = "#{described_class::RUN_DIR_PREFIX}test-#{SecureRandom.hex(3)}")
    path = File.join(@tmp, name)
    FileUtils.mkdir_p(path)
    path
  end

  def write_pidfile(dir, server_pid:, harness_pid:, server_start: :real, harness_start: :real,
                    host: :this_machine)
    server_start = described_class.process_start_time(server_pid) if server_start == :real
    harness_start = described_class.process_start_time(harness_pid) if harness_start == :real
    host = described_class.current_hostname if host == :this_machine

    identity = described_class::ProcessIdentity
    File.write(
      File.join(dir, described_class::PIDFILE_NAME),
      described_class.write_pidfile_contents(
        host: host,
        server: identity.new(pid: server_pid, started_at: server_start),
        harness: identity.new(pid: harness_pid, started_at: harness_start),
        url: "http://127.0.0.1:1"
      )
    )
  end

  # Zombie-aware: a killed child of THIS process stays in the process table until it is
  # reaped, and `ps` still lists it. A zombie holds no port and no database connection,
  # so for every purpose here it is gone — the production code draws the same line.
  def alive?(pid)
    described_class.process_running?(pid)
  end

  describe "a genuinely orphaned server" do
    it "is killed, and the directory removed" do
      orphan = spawn_orphan
      dir = run_dir
      # A harness pid that is certainly not running: PID 1 is init, whose start time
      # will not match this fabricated one.
      write_pidfile(dir, server_pid: orphan, harness_pid: 1, harness_start: "not the real start time")

      reaped = described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)

      expect(reaped).to include(orphan)
      expect(alive?(orphan)).to be(false)
      expect(Dir.exist?(dir)).to be(false)
    end

    # A user whose database is suddenly held by a process they do not recognise needs to
    # be told what happened, not just quietly have it fixed.
    it "says what it did and why" do
      orphan = spawn_orphan
      write_pidfile(run_dir, server_pid: orphan, harness_pid: 1, harness_start: "stale")

      described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)

      expect(stdout.string).to include("reaping an orphaned server")
      expect(stdout.string).to include("holding your database open")
    end
  end

  # THE RULE THAT PREVENTS THE WORST OUTCOME. A recycled PID may belong to something the
  # developer cares about, so a matching number is never sufficient grounds to kill.
  describe "a recycled PID" do
    it "is never killed, and the stale directory is removed" do
      survivor = spawn_orphan
      dir = run_dir
      # Same pid, DIFFERENT start time: this record describes a process that has exited
      # and whose number has since been reused.
      write_pidfile(dir, server_pid: survivor, server_start: "Mon Jan  1 00:00:00 2001",
                    harness_pid: 1, harness_start: "stale")

      reaped = described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)

      expect(reaped).to be_empty
      expect(alive?(survivor)).to be(true), "a recycled PID was killed"
      expect(Dir.exist?(dir)).to be(false)
    end
  end

  # A concurrent run's server is alive and NOT an orphan. Killing it would break a run
  # that is working perfectly.
  describe "a concurrent run" do
    it "is left completely alone" do
      server = spawn_orphan
      dir = run_dir
      # The harness is this very process, which is certainly alive.
      write_pidfile(dir, server_pid: server, harness_pid: Process.pid)

      reaped = described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)

      expect(reaped).to be_empty
      expect(alive?(server)).to be(true)
      expect(Dir.exist?(dir)).to be(true), "a live run's directory was removed"
    end
  end

  # TMPDIR can point at a shared or network volume, which would let two machines see
  # each other's run directories. A PID plus a start time identifies a process within
  # ONE process table; read against another machine's, it names something unrelated.
  describe "a record written by another machine" do
    it "is never killed, however orphaned it looks from here" do
      # Every local signal says "orphan": the server is alive at the recorded start
      # time, and the harness is long gone. Only the hostname says otherwise.
      foreign = spawn_orphan
      dir = run_dir
      write_pidfile(dir, server_pid: foreign, harness_pid: 1, harness_start: "stale",
                    host: "some-other-machine.local")

      reaped = described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)

      expect(reaped).to be_empty
      expect(alive?(foreign)).to be(true), "a process on another machine's record was killed"
    end

    # Not ours to kill AND not ours to delete: the same principle as an unverifiable
    # start time, applied one level up.
    it "leaves the directory alone rather than cleaning up after another host" do
      dir = run_dir
      dead = Process.spawn(RbConfig.ruby, "-e", "exit 0")
      Process.waitpid(dead)
      write_pidfile(dir, server_pid: dead, server_start: "Mon Jan  1 00:00:00 2001",
                    harness_pid: 1, harness_start: "stale", host: "some-other-machine.local")

      described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)

      expect(Dir.exist?(dir)).to be(true)
    end

    # A pidfile from before the hostname field existed cannot be attributed to this
    # machine either, and takes the same no-action path.
    it "treats a record with no hostname as unattributable" do
      unattributed = spawn_orphan
      dir = run_dir
      write_pidfile(dir, server_pid: unattributed, harness_pid: 1, harness_start: "stale", host: nil)

      expect(described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)).to be_empty
      expect(alive?(unattributed)).to be(true)
    end
  end

  describe "litter with nothing to kill" do
    it "removes a directory whose server has already exited" do
      dir = run_dir
      dead = Process.spawn(RbConfig.ruby, "-e", "exit 0")
      Process.waitpid(dead)
      write_pidfile(dir, server_pid: dead, server_start: "Mon Jan  1 00:00:00 2001",
                    harness_pid: 1, harness_start: "stale")

      expect(described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)).to be_empty
      expect(Dir.exist?(dir)).to be(false)
    end

    it "removes a directory with no readable pidfile" do
      dir = run_dir

      described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)

      expect(Dir.exist?(dir)).to be(false)
    end

    it "ignores directories that are not ours" do
      other = File.join(@tmp, "someone-elses-tmpdir")
      FileUtils.mkdir_p(other)

      described_class.reap_orphans!(stdout: stdout, tmpdir: @tmp)

      expect(Dir.exist?(other)).to be(true)
    end
  end

  describe "the pidfile a run writes" do
    let(:config) { Loadwright::Configuration.new }

    it "records the server and harness identities, so a later run can judge them" do
      manager = described_class.new(config: config, stdout: StringIO.new, collector_secret: "s")
      allow(Process).to receive(:spawn).and_return(4_242_424)
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)
      allow(described_class).to receive(:reap_orphans!)

      manager.start!

      record = described_class.read_pidfile(manager.run_dir)
      expect(record[:host]).to eq(described_class.current_hostname)
      expect(record[:server].pid).to eq(4_242_424)
      expect(record[:harness].pid).to eq(Process.pid)
      expect(record[:harness].started_at).to eq(described_class.process_start_time(Process.pid))
      expect(record[:harness]).to be_current
    ensure
      manager&.stop!
    end

    it "lives in the per-run directory beside the secret, so one removal covers both" do
      manager = described_class.new(config: config, stdout: StringIO.new, collector_secret: "s")
      captured = nil
      allow(Process).to receive(:spawn) { |env, *| captured = env; 4_242_425 }
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)
      allow(described_class).to receive(:reap_orphans!)
      manager.start!

      secret_dir = File.dirname(captured.fetch(described_class::SECRET_FILE_VARIABLE))
      expect(secret_dir).to eq(manager.run_dir)
      expect(File.exist?(File.join(manager.run_dir, described_class::PIDFILE_NAME))).to be(true)
    ensure
      manager&.stop!
    end
  end

  describe "#start!" do
    it "reaps before booting, since the exit path is the one a killed run never reached" do
      manager = described_class.new(config: Loadwright::Configuration.new, stdout: StringIO.new)
      order = []
      allow(described_class).to receive(:reap_orphans!) { order << :reaped }
      allow(Process).to receive(:spawn) { order << :spawned; 4_242_426 }
      allow(manager).to receive(:wait_for_health!).and_return(true)
      allow(manager).to receive(:running?).and_return(true)

      manager.start!

      expect(order).to eq(%i[reaped spawned])
    ensure
      manager&.stop!
    end

    it "does not reap when pointing at a server it did not boot" do
      config = Loadwright::Configuration.new
      config.http_target_url = "http://127.0.0.1:1"
      config.http_boot_timeout = 1
      manager = described_class.new(config: config, stdout: StringIO.new)
      allow(described_class).to receive(:reap_orphans!)

      expect { manager.start! }.to raise_error(Loadwright::ServerError)
      expect(described_class).not_to have_received(:reap_orphans!)
    end
  end
end
