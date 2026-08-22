# frozen_string_literal: true

require "json"
require "time"
require "etc"
require "fileutils"
require "securerandom"
require "loadwright/errors"
require "loadwright/history/redactor"

module Loadwright
  module History
    # Persisted run records, so "did my change make it worse?" has something to compare
    # against.
    #
    # A record is written for EVERY run, independent of the human-readable report, and
    # it is the thing `loadwright compare` reads. Three properties matter more than the
    # format:
    #
    # REDACTED ON THE WAY IN. The record holds SQL fingerprints, response shapes,
    # config, and free-text reasons, and it lands in tmp/ where it can be committed,
    # attached to a ticket, or pasted into Slack. Redaction happens here, at write time,
    # not when something renders it -- so a secret never exists in the file at all.
    #
    # WRITTEN EVEN WHEN THE RUN IS INTERRUPTED. `ensure` does not run on a signal, and
    # a partial run record is often the most interesting one: the abort itself is
    # usually the finding. #arm! registers with Lifecycle, which owns the one signal
    # trap, so a Ctrl-C still leaves something to compare against.
    #
    # BOUNDED. run_history_limit records are kept, oldest pruned first. An unbounded
    # directory of run records inside tmp/ is litter that grows with use.
    class RunStore
      BASELINE_FILE = "baseline.json"

      # What a comparison needs to know about the machine, so a latency delta measured
      # on a different one can be labelled unreliable rather than reported as a
      # regression. Query deltas survive a machine change; latency does not.
      Fingerprint = Struct.new(:cpu_count, :memory_bytes, :os, :ruby_version, :database,
                               keyword_init: true) do
        def to_h = { cpu_count: cpu_count, memory_bytes: memory_bytes, os: os,
                     ruby_version: ruby_version, database: database }.compact

        def ==(other) = other.is_a?(Fingerprint) && other.to_h == to_h
      end

      # One stored run, as read back off disk.
      Record = Struct.new(:run_id, :path, :data, keyword_init: true) do
        def metadata = data["metadata"] || {}

        def summary = data["summary"] || {}

        def endpoints = data["endpoints"] || []

        def started_at = metadata["started_at"]

        def git_sha = metadata.dig("git", "sha")

        def dirty? = metadata.dig("git", "dirty") == true

        def fingerprint = metadata["machine"] || {}

        def config_fingerprint = metadata["config_fingerprint"]

        def aborted? = metadata["aborted"] == true

        def endpoint(key) = endpoints.find { |endpoint| endpoint["endpoint"] == key }

        def endpoint_keys = endpoints.map { |endpoint| endpoint["endpoint"] }
      end

      def initialize(config: Loadwright.configuration, redactor: nil, lifecycle: nil, clock: -> { Time.now })
        @config = config
        @redactor = redactor || Redactor.new(config: config)
        @lifecycle = lifecycle
        @clock = clock
        @written = false
      end

      def directory = @config.run_history_dir.to_s

      # Registers a teardown that writes whatever the run has produced so far.
      #
      # The provider is a callable rather than a result, because at the moment this is
      # armed there IS no result yet -- that is the whole point. It returns nil until
      # the engine has something, and a nil provider writes nothing rather than an
      # empty record that would later look like a run with no endpoints.
      def arm!(&result_provider)
        @lifecycle&.register("run history record") do
          next if @written

          result = result_provider.call
          write!(result) if result
        end
        self
      end

      # THE RUNNER CALLS THIS, not the caller of the runner. LoadRunner#build_result
      # persists its own result, so a caller that also calls #write! produces two
      # records for one run -- and the second one then shows up in `runs list` and in
      # every comparison as a separate run.
      def write!(result)
        return nil if result.nil?

        FileUtils.mkdir_p(directory)
        run_id = run_id_for(result)
        path = File.join(directory, "#{run_id}.json")

        File.write(path, JSON.pretty_generate(record_for(result, run_id)))
        @written = true
        prune!

        path
      rescue StandardError => e
        # A run that produced findings must not be lost because history could not be
        # written. Surfaced, never swallowed silently -- but never fatal either.
        warn "loadwright: could not write the run history record (#{e.class}: #{e.message})"
        nil
      end

      # Newest first.
      def list
        Dir.glob(File.join(directory, "*.json"))
           .reject { |path| File.basename(path) == BASELINE_FILE }
           .filter_map { |path| read(path) }
           # run_id breaks a tie: it carries the same timestamp plus a random suffix, so
           # the order is at least stable and reproducible when two records really do
           # share an instant.
           .sort_by { |record| [record.started_at.to_s, record.run_id] }
           .reverse
      end

      def find(run_id)
        return nil if run_id.to_s.empty?

        path = File.join(directory, "#{run_id}.json")
        File.file?(path) ? read(path) : list.find { |record| record.run_id.start_with?(run_id.to_s) }
      end

      def latest = list.first

      def prune!
        excess = list.drop(@config.run_history_limit.to_i)
        excess.each { |record| File.delete(record.path) }
        excess.length
      rescue StandardError
        0
      end

      # ------------------------------------------------------------------- baseline

      # The designated run to compare against, plus the machine's measured noise floor.
      #
      # The noise floor is stored WITH the baseline, not globally, because it is a
      # property of this machine measured on this commit -- run-comparison.md's advice
      # to run the baseline twice and record the variance between them. Without it,
      # regression_threshold_pct is a guess.
      def baseline
        path = File.join(directory, BASELINE_FILE)
        return nil unless File.file?(path)

        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end

      def baseline_record
        pointer = baseline
        pointer && find(pointer["run_id"])
      end

      def set_baseline!(run_id, noise_floor: nil)
        record = find(run_id)
        raise ArgumentError, "no such run: #{run_id}" if record.nil?

        FileUtils.mkdir_p(directory)
        File.write(
          File.join(directory, BASELINE_FILE),
          JSON.pretty_generate({ "run_id" => record.run_id, "noise_floor" => noise_floor,
                                 "set_at" => @clock.call.iso8601 }.compact)
        )
        record
      end

      # ------------------------------------------------------------------- internals

      def read(path)
        data = JSON.parse(File.read(path))
        Record.new(run_id: File.basename(path, ".json"), path: path, data: data)
      rescue StandardError
        nil
      end

      # Timestamp first so the filename sorts chronologically, plus a short random
      # suffix so two runs in the same second do not collide.
      def run_id_for(_result)
        "#{@clock.call.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}"
      end

      def record_for(result, run_id)
        base = result.to_h
        metadata = (base[:metadata] || {}).merge(
          run_id: run_id,
          git: git_metadata,
          machine: machine_fingerprint.to_h,
          # WITH SUB-SECOND PRECISION. Time#to_s serialises to whole seconds, so two
          # runs a few hundred milliseconds apart got identical timestamps and #list's
          # sort became unstable -- which made `latest` return whichever the filesystem
          # happened to hand back, including the baseline being compared against.
          started_at: iso8601(base.dig(:metadata, :started_at)),
          finished_at: iso8601(base.dig(:metadata, :finished_at))
        ).compact

        # ONE redaction pass over the WHOLE document, so a field added anywhere
        # downstream is covered by default rather than by someone remembering.
        @redactor.document(base.merge(metadata: metadata))
      end

      def iso8601(value)
        value.respond_to?(:iso8601) ? value.iso8601(6) : value
      end

      def git_metadata
        {
          sha: git("rev-parse --short HEAD"),
          branch: git("rev-parse --abbrev-ref HEAD"),
          # A run from uncommitted code is still useful; a COMPARISON against it needs a
          # caveat, because the SHA does not fully describe the code that ran.
          dirty: !git("status --porcelain").to_s.empty?
        }.compact
      end

      def git(arguments)
        output = `git #{arguments} 2>/dev/null`.strip
        output.empty? ? nil : output
      rescue StandardError
        nil
      end

      def machine_fingerprint
        Fingerprint.new(
          cpu_count: cpu_count,
          memory_bytes: memory_bytes,
          os: RbConfig::CONFIG["host_os"],
          ruby_version: RUBY_VERSION,
          database: database_version
        )
      end

      def cpu_count
        Etc.nprocessors
      rescue StandardError
        nil
      end

      def memory_bytes
        case RbConfig::CONFIG["host_os"]
        when /darwin/ then Integer(`sysctl -n hw.memsize 2>/dev/null`.strip, exception: false)
        when /linux/ then (File.read("/proc/meminfo")[/MemTotal:\s+(\d+)/, 1]&.to_i || 0) * 1024
        end
      rescue StandardError
        nil
      end

      # Recorded because a Postgres 13 -> 16 upgrade changes plans and therefore
      # latency, which is exactly the kind of difference a comparison must not silently
      # attribute to the developer's change.
      def database_version
        return nil unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connected?

        connection = ::ActiveRecord::Base.connection
        "#{connection.adapter_name} #{connection.database_version}"
      rescue StandardError
        nil
      end
    end
  end
end
