# frozen_string_literal: true

require "shellwords"

# SIGINT DURING AN :http RUN, end to end, with a real signal.
#
# WHY THIS NEEDED ITS OWN FILE. Both halves of this were already specced, and
# separately they both passed:
#
#   * lifecycle_spec proves a real SIGINT reaches the trap, wakes the watcher, runs
#     the interrupt callback before teardown, and runs teardown once.
#   * load_runner_spec proves an interrupted run builds a partial result and
#     persists a partial record.
#
# Neither proves the CHAIN. execution-modes.md asks for "a spec proving SIGINT
# during an :http run still tears down the server, cleans seeded rows, and writes a
# partial report", and that is a different claim: it needs a real child process
# holding a real database connection, real seeded rows, and a real signal arriving
# while requests are in flight. The failure it guards against — a Ctrl-C leaving a
# Puma holding the developer's database and 200k rows behind — is the state a user
# will most often interrupt from, and it is invisible to either half alone.
#
# The signal is real (Process.kill to our own PID) rather than simulated, because a
# simulated one exercises the watcher and skips the trap handler, and the trap
# handler is where the constraints actually bite: no mutex, no I/O object creation.
# `exit_on_signal: false` keeps it from taking the suite down with it.
RSpec.describe "SIGINT during an :http run", :sample_app do
  let(:stdout) { StringIO.new }
  let(:lifecycle) { Loadwright::Lifecycle.new(stderr: StringIO.new) }

  # Deliberately slow enough that the signal lands mid-run rather than after it.
  def configure(config)
    config.execution_mode = :http
    config.scale_factors = [40]
    config.page_size_sweep = [5]
    config.concurrency_levels = [1]
    config.requests_per_endpoint_per_level = 200
    config.warmup_requests = 0
    config.http_boot_timeout = 45
    config.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    rackup = File.join(SampleAppHelpers::APP_ROOT, "config.ru")
    config.http_server_command = "bundle exec puma -p $PORT --threads 1:5 #{Shellwords.escape(rackup)}"
    config
  end

  def endpoints
    [Loadwright::Discovery::Endpoint.new(path: "/api/v1/posts", verb: :get, source: :openapi)]
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # Everything observed while the run is still happening, since most of it is gone
  # by the time teardown finishes — which is the point.
  # Namespaced: a bare `Interrupted` here would land on Object and shadow
  # Loadwright::Interrupted for anything resolving it without the namespace.
  Observed = Struct.new(:server_pid, :rows_after, :partial_result, :report_written,
                        keyword_init: true)

  def interrupt_a_run
    config = configure(Loadwright::Configuration.new)
    SampleApp::Database.reset!

    context = Loadwright::Execution::ExecutionContext.build_http(
      config: config, lifecycle: lifecycle, stdout: stdout
    )
    seeder = Loadwright::Seeding::FactoryBotSeeder.new(config: config, lifecycle: lifecycle, stdout: stdout)
    context.start!
    server_pid = context.server.pid

    partial = nil
    report_written = false
    # The interrupt callback is where the partial report is written, and it runs
    # BEFORE teardown -- teardown deletes the rows and kills the server the report
    # describes.
    lifecycle.trap!(exit_on_signal: false) { report_written = true }

    runner = Loadwright::Engine::LoadRunner.new(
      config: config, context: context, seeder: seeder,
      resolver: Loadwright::Discovery::PathParamResolver.new(config: config),
      lifecycle: lifecycle, stdout: stdout
    )

    thread = Thread.new { partial = runner.run(endpoints: endpoints) }

    # Wait until the run is genuinely under way -- a signal delivered before the
    # first request would prove nothing about tearing down mid-flight.
    deadline = Time.now + 30
    sleep 0.05 while runner.cells.empty? && thread.alive? && Time.now < deadline

    Process.kill("INT", Process.pid)
    thread.join(30)
    lifecycle.instance_variable_get(:@watcher)&.join(30)

    Observed.new(
      server_pid: server_pid,
      rows_after: { posts: Post.count, comments: Comment.count, authors: Author.count },
      partial_result: partial,
      report_written: report_written
    )
  ensure
    lifecycle.untrap!
    lifecycle.run_teardown!
  end

  # One interrupted run, shared: it boots a real server and seeds 40 posts, and doing
  # that per example would be slow and would make one boot failure look like four.
  before(:context) do
    @interrupted = nil
  end

  let(:interrupted) { @interrupted ||= interrupt_a_run }

  it "tears the booted server down rather than leaving it holding the database" do
    expect(interrupted.server_pid).not_to be_nil
    expect(process_alive?(interrupted.server_pid)).to be(false),
                                                      "a Puma survived the interrupt and is still " \
                                                      "holding the developer's database open"
  end

  # Not a blanket TRUNCATE -- the seeder deletes only the rows it created, tracked by
  # id. The fixture starts empty, so zero here is both.
  it "cleans up the rows it seeded" do
    expect(interrupted.rows_after).to eq(posts: 0, comments: 0, authors: 0)
  end

  it "runs the partial-report callback before teardown destroys what it describes" do
    expect(interrupted.report_written).to be(true)
  end

  # An aborted run producing no output at all is a bug: the abort is usually the most
  # interesting finding in it.
  it "still returns a result, marked as the partial thing it is" do
    result = interrupted.partial_result

    expect(result).to be_a(Loadwright::Reporting::RunResult)
    expect(result).to be_aborted
    expect(result.metadata[:aborted_reason]).to eq("interrupted")
  end

  it "keeps whatever it managed to measure before the signal" do
    expect(interrupted.partial_result.cells).not_to be_empty
  end

  # The three formats all have to survive a partial result, since this is exactly the
  # run someone will look at hardest.
  it "renders a report that says outright that it is partial" do
    html = Loadwright::Reporting::HtmlReport.new.render(interrupted.partial_result)
    markdown = Loadwright::Reporting::MarkdownReport.new.render(interrupted.partial_result)

    expect(html).to include("Partial run")
    expect(markdown).to include("**Partial run.**")
  end
end
