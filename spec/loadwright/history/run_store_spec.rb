# frozen_string_literal: true

require "tmpdir"

RSpec.describe Loadwright::History::RunStore do
  let(:config) { Loadwright::Configuration.new }

  around do |example|
    Dir.mktmpdir("run-store-") do |dir|
      config.run_history_dir = dir
      @dir = dir
      example.run
    end
  end

  # A clock that advances, so "newest first" and pruning order are real orderings
  # rather than whatever the filesystem happened to return.
  def store(seconds: nil, lifecycle: nil, redactor: nil)
    tick = -1
    clock = seconds ? -> { Time.at(1_700_000_000 + (tick += 1) * 60) } : -> { Time.now }

    described_class.new(config: config, lifecycle: lifecycle, redactor: redactor, clock: clock)
  end

  def result(outcomes: [], cells: [], **rest)
    Loadwright::Reporting::RunResult.new(
      config: config, cells: cells, outcomes: outcomes,
      started_at: Time.now, finished_at: Time.now, **rest
    )
  end

  describe "#write!" do
    it "writes a record per run" do
      subject = store(seconds: true)
      subject.write!(result)
      subject.write!(result)

      expect(subject.list.length).to eq(2)
    end

    it "records the git SHA, branch, and whether the worktree was dirty" do
      record = store.tap { |s| s.write!(result) }.latest

      expect(record.metadata["git"]).to include("sha", "dirty")
    end

    it "records a machine fingerprint, so a latency delta from another machine can be caveated" do
      record = store.tap { |s| s.write!(result) }.latest

      expect(record.fingerprint).to include("cpu_count", "os", "ruby_version")
    end

    it "records the resolved config, so a comparison can name which key diverged" do
      config.concurrency_levels = [1, 9]
      record = store.tap { |s| s.write!(result) }.latest

      expect(record.metadata.dig("config", "concurrency_levels", "value")).to eq([1, 9])
      expect(record.config_fingerprint).to eq(config.comparability_fingerprint)
    end

    # =======================================================================
    # REDACTED ON THE WAY IN. The record lands in tmp/, where it can be committed,
    # attached to a ticket, or pasted into Slack. Redacting when something renders it
    # would leave the raw values sitting in the file.
    # =======================================================================
    # A cell that serialises the things a record must not keep. Only the handful of
    # methods RunResult actually calls on a cell are stubbed; the point is what reaches
    # the FILE, not the cell's own shape.
    def leaky_cell
      instance_double(
        Loadwright::Engine::LoadRunner::Cell,
        sweep: :seed_scale, scale_factor: 1, endpoint_key: "GET /a", median_records: 5,
        to_h: {
          endpoint: "GET /a",
          queries: [{ fingerprint: "SELECT * FROM u WHERE e = ?",
                      sql: "SELECT * FROM u WHERE e = 'ceo@acme.com'" }]
        }
      )
    end

    it "keeps no raw SQL, whatever the run handed it" do
      subject = store
      subject.write!(result(cells: [leaky_cell]))

      contents = File.read(subject.latest.path)
      expect(contents).not_to include("ceo@acme.com")
      # The fingerprint survives -- it is what every finding is built from.
      expect(contents).to include("SELECT * FROM u WHERE e = ?")
    end

    # The reasons inside Measurement.unavailable and capability downgrade causes read as
    # internal metadata, which is exactly why they get missed. They are persisted here
    # like everything else, so they are redacted here like everything else.
    it "redacts free-text reasons, not just obviously sensitive fields" do
      subject = store
      subject.write!(result(aborted_reason: "the app at http://staging.acme.internal:3000 stopped answering"))

      contents = File.read(subject.latest.path)
      expect(contents).not_to include("staging.acme.internal")
      expect(contents).to include("stopped answering")
    end

    # Losing a run's findings because history could not be written would be a worse
    # outcome than losing the history.
    it "warns rather than raising when the directory cannot be written" do
      config.run_history_dir = "/proc/definitely-not-writable"
      subject = store

      expect { expect(subject.write!(result)).to be_nil }.to output(/could not write/).to_stderr
    end
  end

  describe "#prune!" do
    it "keeps run_history_limit records, oldest first out" do
      config.run_history_limit = 3
      subject = store(seconds: true)
      5.times { subject.write!(result) }

      expect(subject.list.length).to eq(3)
    end

    it "never prunes the baseline pointer file itself" do
      config.run_history_limit = 1
      subject = store(seconds: true)
      subject.write!(result)
      subject.set_baseline!(subject.latest.run_id)
      subject.write!(result)

      expect(File.exist?(File.join(@dir, described_class::BASELINE_FILE))).to be(true)
      expect(subject.list.length).to eq(1)
    end
  end

  # ==========================================================================
  # `ensure` DOES NOT RUN ON A SIGNAL, and the partial record is often the most
  # interesting one -- the abort itself is usually the finding, and it is what the
  # partial-report path reads from.
  # ==========================================================================
  describe "#arm! -- surviving an interruption" do
    it "writes whatever the run produced when Lifecycle tears down" do
      lifecycle = Loadwright::Lifecycle.new(stderr: StringIO.new)
      subject = store(lifecycle: lifecycle)
      partial = result

      subject.arm! { partial }
      lifecycle.run_teardown!

      expect(subject.list.length).to eq(1)
    end

    it "does not write twice when the run finished normally first" do
      lifecycle = Loadwright::Lifecycle.new(stderr: StringIO.new)
      subject = store(lifecycle: lifecycle)

      subject.arm! { result }
      subject.write!(result)
      lifecycle.run_teardown!

      expect(subject.list.length).to eq(1)
    end

    # An empty record would later read as a run that found nothing, which is a
    # different claim from a run that never got started.
    it "writes nothing when the run produced no result at all" do
      lifecycle = Loadwright::Lifecycle.new(stderr: StringIO.new)
      subject = store(lifecycle: lifecycle)

      subject.arm! { nil }
      lifecycle.run_teardown!

      expect(subject.list).to be_empty
    end
  end

  describe "the baseline" do
    it "points at a designated run and remembers the measured noise floor" do
      subject = store
      subject.write!(result)
      run_id = subject.latest.run_id

      subject.set_baseline!(run_id, noise_floor: 0.18)

      expect(subject.baseline["run_id"]).to eq(run_id)
      expect(subject.baseline["noise_floor"]).to eq(0.18)
      expect(subject.baseline_record.run_id).to eq(run_id)
    end

    it "refuses to point at a run that does not exist" do
      expect { store.set_baseline!("nope") }.to raise_error(ArgumentError, /no such run/)
    end
  end

  # Time#to_s serialises to whole seconds, so two runs a few hundred milliseconds apart
  # got identical timestamps and the sort became unstable -- `latest` then returned
  # whichever the filesystem happened to hand back.
  describe "ordering" do
    it "orders runs written within the same second" do
      subject = store
      first = subject.tap { |s| s.write!(result) }.latest.run_id
      second = subject.tap { |s| s.write!(result) }.latest.run_id

      expect(first).not_to eq(second)
      expect(subject.list.first.run_id).to eq(second)
    end

    it "records timestamps with sub-second precision" do
      record = store.tap { |s| s.write!(result) }.latest

      expect(record.started_at).to match(/\d{2}:\d{2}:\d{2}\.\d{6}/)
    end
  end

  describe "#find" do
    it "accepts a run id prefix, since nobody types a full one" do
      subject = store
      subject.write!(result)
      full = subject.latest.run_id

      expect(subject.find(full[0, 8]).run_id).to eq(full)
    end

    it "is nil for an unknown id rather than raising" do
      expect(store.find("nope")).to be_nil
    end
  end
end
