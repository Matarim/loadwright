# frozen_string_literal: true

RSpec.describe Loadwright::CapabilityProfile do
  describe ".derive" do
    context "with :in_process transport and the direct collector" do
      subject(:profile) { described_class.derive(transport: :in_process, collector: :direct) }

      it "measures every query-structure signal" do
        expect(profile).to be_available(:n_plus_one_pattern_match)
        expect(profile).to be_available(:n_plus_one_slope)
        expect(profile).to be_available(:queries_per_returned_record)
        expect(profile).to be_available(:over_fetch_hint)
        expect(profile).to be_available(:response_validity_gate)
        expect(profile).to be_available(:explain_index_analysis)
      end

      # execution-modes.md: these must be reported as unavailable, never as a
      # number and never as zero. There is no real thread pool here.
      it "suppresses concurrency-dependent signals rather than fabricating them" do
        %i[latency_under_concurrency connection_pool_exhaustion true_client_latency].each do |signal|
          expect(profile).to be_unavailable(signal), "expected #{signal} to be unavailable"
          expect(profile.reason_for(signal)).to match(/no server thread pool/)
        end
      end

      it "marks the pool-vs-threads check partial, since only the static half works" do
        expect(profile).to be_partial(:pool_vs_threads_static_check)
        expect(profile.reason_for(:pool_vs_threads_static_check)).to match(/static config comparison only/)
      end

      it "cannot attribute memory cleanly, sharing a heap with the app" do
        expect(profile).to be_unavailable(:clean_memory_attribution)
      end
    end

    context "with :http transport and the collector middleware installed" do
      subject(:profile) { described_class.derive(transport: :http, collector: :middleware) }

      it "measures every signal the collector actually carries" do
        expect(profile.available_signals)
          .to match_array(described_class::SIGNALS - described_class::NOT_COLLECTED_SIGNALS)
      end

      # THE TWO THIS RUN CANNOT ANSWER EITHER, and the reason is the gem's own
      # unfinished work rather than anything about the transport. MemoryTracker and
      # ConnectionPoolTracker are built and specced and nothing in a run instantiates
      # either, so advertising these as `available` put a claim in the report's "what
      # this run could measure" section that no number in the report supported.
      #
      # Stated here rather than left implicit, so wiring the collectors up has to
      # come back and delete this example on purpose.
      it "does not advertise the signals nothing collects yet" do
        described_class::NOT_COLLECTED_SIGNALS.each do |signal|
          expect(profile).to be_unavailable(signal)
          expect(profile.reason_for(signal)).to include("not collected yet")
        end
      end
    end

    # This is the case the whole three-seam design exists for: same transport as
    # the fully-instrumented run above, dramatically less capability. Keying
    # capability off execution_mode would report these as measured.
    context "with :http transport against a target that does not load the gem" do
      subject(:profile) { described_class.derive(transport: :http, collector: :external) }

      it "cannot produce any query-derived signal" do
        %i[
          n_plus_one_pattern_match n_plus_one_slope queries_per_returned_record
          over_fetch_hint time_breakdown_db_view_gc explain_index_analysis
        ].each do |signal|
          expect(profile).to be_unavailable(signal), "expected #{signal} to be unavailable"
          expect(profile.reason_for(signal)).to match(/no collector middleware/)
        end
      end

      # response-analysis.md: report the available subset rather than dropping
      # the endpoint entirely.
      it "keeps the purely response-derived signals" do
        expect(profile).to be_available(:response_validity_gate)
        expect(profile).to be_available(:payload_growth_pagination)
        expect(profile).to be_available(:true_client_latency)
        expect(profile).to be_available(:cold_vs_warm_cache)
      end

      it "differs from the same transport with middleware present" do
        instrumented = described_class.derive(transport: :http, collector: :middleware)
        expect(profile).not_to eq(instrumented)
      end
    end

    it "rejects an unknown transport or collector" do
      expect { described_class.derive(transport: :carrier_pigeon, collector: :direct) }
        .to raise_error(ArgumentError, /unknown transport/)
      expect { described_class.derive(transport: :http, collector: :telepathy) }
        .to raise_error(ArgumentError, /unknown collector/)
    end
  end

  describe "#degrade" do
    subject(:profile) { described_class.derive(transport: :http, collector: :middleware) }

    it "returns a new profile and leaves the original untouched" do
      degraded = profile.degrade(:queries_per_returned_record, reason: "middleware stopped responding")

      expect(degraded).not_to equal(profile)
      expect(profile).to be_available(:queries_per_returned_record)
      expect(degraded).to be_unavailable(:queries_per_returned_record)
      expect(degraded.reason_for(:queries_per_returned_record)).to eq("middleware stopped responding")
    end

    it "degrades several signals at once" do
      degraded = profile.degrade(%i[n_plus_one_slope over_fetch_hint], reason: "app process died")
      expect(degraded).to be_unavailable(:n_plus_one_slope)
      expect(degraded).to be_unavailable(:over_fetch_hint)
    end

    it "requires a reason" do
      expect { profile.degrade(:n_plus_one_slope, reason: " ") }
        .to raise_error(ArgumentError, /requires a reason/)
    end

    it "rejects unknown signals" do
      expect { profile.degrade(:vibes, reason: "x") }.to raise_error(ArgumentError, /unknown signal/)
    end

    it "is frozen" do
      expect(profile).to be_frozen
    end
  end

  describe "#intersect" do
    # run-comparison.md permits a cross-mode comparison on query metrics alone,
    # clearly labelled partial. That is this operation.
    it "keeps only what both profiles can measure" do
      in_process = described_class.derive(transport: :in_process, collector: :direct)
      http = described_class.derive(transport: :http, collector: :middleware)
      intersection = in_process.intersect(http)

      expect(intersection).to be_available(:n_plus_one_slope)
      expect(intersection).to be_unavailable(:latency_under_concurrency)
    end
  end

  describe "the signal set" do
    # AGENTS.md section 5.1 is the user-facing statement of what is measurable
    # in which mode. If it and this constant drift, agents give confidently
    # wrong advice about what a run can tell them.
    it "matches AGENTS.md's capability matrix exactly" do
      matrix = SpecPaths.read(SpecPaths::AGENTS_MD)[/### 5\.1.*?```yaml\n(.*?)```/m, 1]
      expect(matrix).not_to be_nil, "could not locate the capability matrix in AGENTS.md section 5.1"

      documented = matrix.scan(/^\s{2}([a-z0-9_]+):/).flatten.map(&:to_sym)

      expect(documented).to match_array(described_class::SIGNALS)
    end

    # THE VALUES, not just the signal names. The example above only proves the
    # table lists the right rows -- it passed happily while the table claimed
    # explain_index_analysis and connection_pool_exhaustion were available under
    # :http, which is false for a remote target that the middleware cannot reach.
    #
    # That is the exact failure this file exists to prevent: an agent reading a
    # stale matrix tells a user a signal is trustworthy when the run never
    # measured it. Names drifting is cosmetic; values drifting is a wrong answer.
    it "states each signal's real availability in each transport+collector pairing" do
      matrix = SpecPaths.read(SpecPaths::AGENTS_MD)[/### 5\.1.*?```yaml\n(.*?)```/m, 1]

      columns = [
        described_class.derive(transport: :in_process, collector: :direct),
        described_class.derive(transport: :http, collector: :middleware),
        described_class.derive(transport: :http, collector: :external)
      ]

      wrong = matrix.each_line.filter_map do |line|
        match = line.match(/^\s{2}([a-z0-9_]+):\s+(\S+)\s+(\S+)\s+(\S+)\s*$/)
        next unless match

        signal = match[1].to_sym
        documented = match[2..4].map { |cell| cell.downcase.to_sym }
        actual = columns.map { |profile| profile.signals[signal].status }

        "#{signal}: AGENTS.md says #{documented.inspect}, actual #{actual.inspect}" if documented != actual
      end

      expect(wrong).to be_empty, "AGENTS.md section 5.1 disagrees with CapabilityProfile:\n  #{wrong.join("\n  ")}"
    end
  end
end
