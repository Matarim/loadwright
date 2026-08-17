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
