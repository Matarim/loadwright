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
      expect(File.read(path)).to eq("s3cr3t-per-run")
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

    def write(contents, mode)
      path = File.join(@dir, "secret")
      File.write(path, contents)
      File.chmod(mode, path)
      path
    end

    it "reads a private file" do
      expect(described_class.read_secret_file(write("abc123", 0o600))).to eq("abc123")
    end

    # A world-readable secret file has already failed at its one job. Arming the
    # endpoint anyway would pretend the secret was protected when it was not.
    it "refuses a file other users can read" do
      expect { expect(described_class.read_secret_file(write("abc123", 0o644))).to be_nil }
        .to output(/readable by other users/).to_stderr
    end

    it "refuses a group-readable file too" do
      expect(described_class.read_secret_file(write("abc123", 0o640))).to be_nil
    end

    it "is nil for a missing path, an empty path, and an empty file" do
      expect(described_class.read_secret_file(nil)).to be_nil
      expect(described_class.read_secret_file("")).to be_nil
      expect(described_class.read_secret_file(File.join(@dir, "nope"))).to be_nil
      expect(described_class.read_secret_file(write("   ", 0o600))).to be_nil
    end
  end
end
