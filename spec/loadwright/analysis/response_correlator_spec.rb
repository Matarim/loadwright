# frozen_string_literal: true

RSpec.describe Loadwright::Analysis::ResponseCorrelator do
  let(:config) { Loadwright::Configuration.new }
  let(:full_capability) { Loadwright::CapabilityProfile.derive(transport: :in_process, collector: :direct) }
  let(:degraded_capability) { Loadwright::CapabilityProfile.derive(transport: :http, collector: :external) }

  def correlator(capability: full_capability)
    described_class.new(config: config, capability: capability)
  end

  def observation(records:, queries:, bytes: nil, seeded: nil, page_size: nil, label: nil)
    described_class::Observation.new(
      label: label, records: records, queries: queries, bytes: bytes, seeded: seeded, page_size: page_size
    )
  end

  # THE REGRESSION TEST THIS SUBSYSTEM EXISTS FOR (response-analysis.md Part 2).
  #
  # A properly paginated endpoint with a severe N+1: it returns the same 25 records
  # whether the table holds 10 rows or 10,000, so its query count is FLAT against
  # seeded scale and a seeded-scale slope calls it perfectly healthy. Only varying the
  # RETURNED record count exposes it.
  describe "a paginated endpoint with an N+1" do
    # The seed-scale sweep: seeded rows vary 10 -> 10,000, page size fixed. The
    # endpoint returns 25 records every time and issues 26 queries every time.
    let(:seed_scale_sweep) do
      [
        observation(records: 25, queries: 26, seeded: 10, page_size: 25),
        observation(records: 25, queries: 26, seeded: 100, page_size: 25),
        observation(records: 25, queries: 26, seeded: 1_000, page_size: 25),
        observation(records: 25, queries: 26, seeded: 10_000, page_size: 25)
      ]
    end

    # The page-size sweep: page size varies, seed scale fixed high enough to fill the
    # largest page. Returned records vary, and the query count tracks them.
    let(:page_size_sweep) do
      [
        observation(records: 5, queries: 6, seeded: 10_000, page_size: 5),
        observation(records: 25, queries: 26, seeded: 10_000, page_size: 25),
        observation(records: 100, queries: 101, seeded: 10_000, page_size: 100)
      ]
    end

    it "reports the seeded-scale sweep as not measurable, NOT as flat and healthy" do
      measurement = correlator.n_plus_one_slope(seed_scale_sweep)

      expect(measurement).to be_unavailable
      expect(measurement.reason).to include("unable to vary result size")
      expect(measurement.reason).to include("NOT a flat/healthy result")
    end

    it "catches the N+1 from the page-size sweep, where the seeded sweep could not" do
      measurement = correlator.n_plus_one_slope(page_size_sweep)

      expect(measurement).to be_available
      # One extra query per additional record returned: the textbook signature.
      expect(measurement.value).to be_within(0.02).of(1.0)
    end

    it "raises an n_plus_one_slope finding from the page-size sweep" do
      findings = correlator.findings(observations: page_size_sweep)

      finding = findings.find { |f| f.kind == :n_plus_one_slope }
      expect(finding).not_to be_nil
      expect(finding.confidence).to eq(:high)
      expect(finding.detail).to include("pagination hides")
    end

    # The crucial negative: the seeded sweep must not emit a clean slope verdict.
    #
    # It also must not emit a FINDING. An earlier version emitted a
    # `confidence: :none` "not measurable" finding, which was a category error —
    # "finding" says something is wrong with the app, when what is true is that a
    # detector could not answer. Unavailability lives in the Measurement (which carries
    # the reason) and in Coverage, which is what the outcome state is derived from.
    it "emits no finding at all for an unmeasurable slope" do
      findings = correlator.findings(observations: seed_scale_sweep)

      expect(findings.map(&:kind)).not_to include(:n_plus_one_slope)
      expect(findings.map(&:confidence)).not_to include(:none)
    end

    it "reports the unmeasurable slope through Coverage instead" do
      states = correlator.detector_states(observations: seed_scale_sweep, query_data: true)

      expect(states[:slope].first).to eq(:unavailable)
      expect(states[:slope].last).to include("unable to vary result size")
      # And the class is still COVERED, because the pattern-match detector answered.
      expect(Loadwright::Coverage.new(states)).to be_covered(:n_plus_one)
    end
  end

  describe "#n_plus_one_slope" do
    it "is near zero for a correctly batched endpoint" do
      measurement = correlator.n_plus_one_slope([
                                                  observation(records: 5, queries: 3),
                                                  observation(records: 25, queries: 3),
                                                  observation(records: 100, queries: 4)
                                                ])

      expect(measurement.value).to be < 0.1
    end

    it "needs at least two cells" do
      expect(correlator.n_plus_one_slope([observation(records: 5, queries: 6)])).to be_unavailable
    end

    it "ignores cells with no query count rather than treating them as zero" do
      measurement = correlator.n_plus_one_slope([
                                                  observation(records: 5, queries: nil),
                                                  observation(records: 100, queries: nil)
                                                ])

      expect(measurement).to be_unavailable
      expect(measurement.reason).to include("no cell produced both")
    end
  end

  describe "#queries_per_record" do
    it "is low for a healthy endpoint" do
      measurement = correlator.queries_per_record([
                                                    observation(records: 25, queries: 3),
                                                    observation(records: 100, queries: 3)
                                                  ])

      expect(measurement.value).to be < described_class::HEALTHY_RATIO
    end

    it "is near one for an N+1" do
      measurement = correlator.queries_per_record([observation(records: 25, queries: 26)])

      expect(measurement.value).to be_within(0.05).of(1.04)
    end

    it "refuses to divide by zero records" do
      measurement = correlator.queries_per_record([observation(records: 0, queries: 1)])

      expect(measurement).to be_unavailable
      expect(measurement.reason).to include("nothing to divide by")
    end
  end

  describe "#payload_growth" do
    # No query-count signal will ever surface this: loading 10,000 records can be a
    # single efficient query.
    it "correlates strongly for an unbounded collection" do
      measurement = correlator.payload_growth([
                                                observation(records: 10, queries: 1, bytes: 1_000, seeded: 10),
                                                observation(records: 100, queries: 1, bytes: 10_000, seeded: 100),
                                                observation(records: 1_000, queries: 1, bytes: 100_000, seeded: 1_000)
                                              ])

      expect(measurement.value).to be > 0.9
    end

    it "does not correlate for a paginated endpoint" do
      measurement = correlator.payload_growth([
                                                observation(records: 25, queries: 26, bytes: 2_000, seeded: 10),
                                                observation(records: 25, queries: 26, bytes: 2_000, seeded: 1_000)
                                              ])

      expect(measurement.value).to eq(0.0)
    end

    it "needs more than one seed scale" do
      measurement = correlator.payload_growth([
                                                observation(records: 5, queries: 1, bytes: 100, seeded: 10),
                                                observation(records: 5, queries: 1, bytes: 100, seeded: 10)
                                              ])

      expect(measurement).to be_unavailable
      expect(measurement.reason).to include("only one seed scale")
    end

    it "raises a missing_pagination finding above the configured threshold" do
      findings = correlator.findings(observations: [
                                       observation(records: 10, queries: 1, bytes: 1_000, seeded: 10),
                                       observation(records: 1_000, queries: 1, bytes: 100_000, seeded: 1_000)
                                     ])

      finding = findings.find { |f| f.kind == :missing_pagination }
      expect(finding.detail).to include("one query can load ten thousand rows")
    end

    it "warns on an oversized payload independently of growth" do
      config.max_response_bytes_warning = 1_024
      findings = correlator.findings(observations: [observation(records: 1, queries: 1, bytes: 5_000, seeded: 1)])

      expect(findings.map(&:kind)).to include(:oversized_payload)
    end
  end

  describe "#findings for the pattern-match signal" do
    # Reported ALONGSIDE the slope rather than merged with it: they catch different
    # failure modes and disagreement between them is itself informative.
    it "reports duplicate fingerprints from a single request" do
      duplicates = {
        "SELECT * FROM comments WHERE post_id = ?" => Array.new(25) do
          { fingerprint: "SELECT * FROM comments WHERE post_id = ?",
            call_site: { path: "/app/serializers/post_serializer.rb", line: 12, label: "comments_count" } }
        end
      }

      finding = correlator.findings(observations: [], duplicates: duplicates).first

      expect(finding.kind).to eq(:n_plus_one_pattern_match)
      expect(finding.detail).to include("ran 25 times in a single request")
      expect(finding.evidence[:call_site][:path]).to include("post_serializer")
    end

    it "ignores a fingerprint seen only twice, which is normal" do
      duplicates = { "SELECT 1" => [{ fingerprint: "SELECT 1" }, { fingerprint: "SELECT 1" }] }

      expect(correlator.findings(observations: [], duplicates: duplicates)).to be_empty
    end

    # ONE SIGNATURE, TWO DEFECTS. A request that finds the same already-loaded row
    # four times looks exactly like a per-record N+1 inside a single request, and
    # `includes` fixes only one of them. What separates them is whether the repeat
    # count moved when the endpoint returned more records -- which is data the run
    # already has, across cells.
    describe "a repeat that did not grow with the records returned" do
      let(:duplicates) do
        sql = 'SELECT "warehouses".* FROM "warehouses" WHERE "warehouses"."id" = ?'
        { sql => Array.new(4) { { fingerprint: sql } } }
      end

      it "says so, and stops advising a preload" do
        flat = [observation(records: 5, queries: 12), observation(records: 50, queries: 12)]

        finding = correlator.findings(observations: flat, duplicates: duplicates).first

        expect(finding.evidence[:scaling]).to eq(:fixed)
        expect(finding.detail).to include("fixed number of repeats per request")
        expect(finding.suggestion).to include("Pass the loaded object down")
      end

      it "advises the preload where the count did grow" do
        scaling = [observation(records: 5, queries: 12), observation(records: 50, queries: 60)]

        finding = correlator.findings(observations: scaling, duplicates: duplicates).first

        expect(finding.evidence[:scaling]).to eq(:scaling)
        expect(finding.suggestion).to include("includes(:warehouse)")
      end

      # Flatness that was never measured is not flatness: one cell, or cells that all
      # returned the same number of records AND the same seeded scale, answers nothing.
      it "claims nothing either way when neither axis varied" do
        same = [observation(records: 5, queries: 12, seeded: 10),
                observation(records: 5, queries: 12, seeded: 10)]

        finding = correlator.findings(observations: same, duplicates: duplicates).first

        expect(finding.evidence).not_to have_key(:scaling)
        expect(finding.suggestion).to include("could not tell which kind of repeat")
      end

      # THE AXIS STILL AVAILABLE. An endpoint answering with a single object has no
      # record count to read, so on an API made mostly of detail endpoints the
      # classifier had no input at all and abstained on every finding -- correctly, and
      # with nothing else to ask. Seeded scale is weaker and real: a query count
      # identical at seed scale 1 and seed scale 100 did not move while the data under
      # it moved a hundredfold.
      it "falls back to seeded scale when no record count could be read" do
        no_records = [observation(records: nil, queries: 12, seeded: 1),
                      observation(records: nil, queries: 12, seeded: 100)]

        finding = correlator.findings(observations: no_records, duplicates: duplicates).first

        expect(finding.evidence[:scaling]).to eq(:fixed_by_seed_scale)
        expect(finding.suggestion).to include("pass the loaded object down")
      end

      # It is a WEAKER measurement and gets its own value rather than being folded into
      # :fixed, because a paginated collection is flat against seeded scale by
      # construction -- exactly what a per-record N+1 behind pagination looks like.
      it "names the assumption that fallback rests on" do
        no_records = [observation(records: nil, queries: 12, seeded: 1),
                      observation(records: nil, queries: 12, seeded: 100)]

        finding = correlator.findings(observations: no_records, duplicates: duplicates).first

        expect(finding.suggestion).to include("PAGINATED")
        expect(finding.detail).to include("could not be read")
      end

      # The returned-record axis wins wherever it is available: it is the denominator
      # the whole design is built on, and the fallback exists only for its absence.
      it "prefers the record-count axis when it has one" do
        both = [observation(records: 5, queries: 12, seeded: 1),
                observation(records: 50, queries: 12, seeded: 100)]

        finding = correlator.findings(observations: both, duplicates: duplicates).first

        expect(finding.evidence[:scaling]).to eq(:fixed)
      end
    end

    it "reports both signals when both fire, rather than collapsing them" do
      duplicates = { "SELECT x" => Array.new(10) { { fingerprint: "SELECT x" } } }
      observations = [observation(records: 5, queries: 6), observation(records: 50, queries: 51)]

      kinds = correlator.findings(observations: observations, duplicates: duplicates).map(&:kind)

      expect(kinds).to include(:n_plus_one_pattern_match, :n_plus_one_slope)
    end
  end

  # A tool that cries wolf about legitimate authorization queries gets uninstalled.
  describe "over-fetch is a hint, never a finding" do
    it "is emitted with low confidence" do
      findings = correlator.findings(
        observations: [], tables_queried: %w[posts comments audit_logs], response_keys: %w[id title]
      )

      finding = findings.find { |f| f.kind == :over_fetch_hint }
      expect(finding.confidence).to eq(:low)
      expect(finding).to be_hint
      expect(finding.detail).to include("worth checking")
      expect(finding.detail).to include("legitimately loaded for authorisation")
    end

    it "never contributes to a non-zero exit code" do
      findings = correlator.findings(
        observations: [], tables_queried: %w[audit_logs], response_keys: %w[id]
      )

      # The rule the reporting layer will apply: hints are excluded from any
      # pass/fail decision.
      expect(findings.reject(&:hint?)).to be_empty
    end

    it "does not fire when the queried tables all appear in the response" do
      findings = correlator.findings(
        observations: [], tables_queried: %w[posts comments], response_keys: %w[id post_id comment_body]
      )

      expect(findings.map(&:kind)).not_to include(:over_fetch_hint)
    end

    it "respects detect_overfetching = false" do
      config.detect_overfetching = false

      findings = correlator.findings(observations: [], tables_queried: %w[audit_logs], response_keys: %w[id])

      expect(findings).to be_empty
    end
  end

  # Nothing here may branch on execution_mode; capability is the only input.
  describe "capability gating" do
    it "reports query-derived signals as unavailable under a degraded collector" do
      subject = correlator(capability: degraded_capability)
      observations = [observation(records: 5, queries: 6), observation(records: 50, queries: 51)]

      expect(subject.n_plus_one_slope(observations)).to be_unavailable
      expect(subject.queries_per_record(observations)).to be_unavailable
      expect(subject.n_plus_one_slope(observations).reason).to include("no collector middleware")
    end

    # response-analysis.md: report the available subset rather than dropping the
    # endpoint entirely. A degraded run is still useful.
    it "keeps payload growth working under a degraded collector" do
      subject = correlator(capability: degraded_capability)
      observations = [
        observation(records: 10, queries: nil, bytes: 1_000, seeded: 10),
        observation(records: 1_000, queries: nil, bytes: 100_000, seeded: 1_000)
      ]

      expect(subject.payload_growth(observations)).to be_available
      expect(subject.findings(observations: observations).map(&:kind)).to include(:missing_pagination)
    end

    it "does not emit an over-fetch hint it cannot substantiate" do
      subject = correlator(capability: degraded_capability)

      findings = subject.findings(observations: [], tables_queried: %w[audit_logs], response_keys: %w[id])

      expect(findings).to be_empty
    end

    it "carries capability reasons into serialisation rather than nils" do
      subject = correlator(capability: degraded_capability)

      audit = subject.to_h([observation(records: 5, queries: nil, bytes: 10, seeded: 5)])

      expect(audit[:queries_per_returned_record]).to have_key(:unavailable)
      expect(audit[:queries_per_returned_record][:unavailable]).to include("no collector middleware")
    end
  end
  # A REPEAT BELOW THE THRESHOLD USED TO PRODUCE SILENCE, so an endpoint issuing the
  # same query twice per request sat in the clean list looking identical to one that
  # issued it once. That silence is how three endpoints moved from a high-confidence
  # finding to "healthy" across four rounds with nothing anywhere to explain it: the
  # counts were being fixed, and the endpoints that fell under the threshold as a
  # result simply stopped being mentioned.
  describe "duplicate queries under the reporting threshold" do
    let(:twice) { { "SELECT 1" => Array.new(2) { { fingerprint: "SELECT 1" } } } }

    it "is still not a finding" do
      expect(correlator.findings(observations: [], duplicates: twice)).to be_empty
    end

    it "is reported on the endpoint rather than dropped" do
      summary = correlator.to_h([], twice)[:sub_threshold_duplicates]

      expect(summary[:occurrences]).to eq(2)
      expect(summary[:threshold]).to eq(3)
      expect(summary[:note]).to include("under the reporting threshold")
    end

    it "says which knob turns it into a finding" do
      expect(correlator.to_h([], twice)[:sub_threshold_duplicates][:note])
        .to include("n_plus_one_duplicate_threshold")
    end

    it "says nothing for an endpoint with no repeats at all" do
      expect(correlator.to_h([], {})).not_to have_key(:sub_threshold_duplicates)
    end

    it "says nothing once the repeat is a finding in its own right" do
      thrice = { "SELECT 1" => Array.new(3) { { fingerprint: "SELECT 1" } } }

      expect(correlator.to_h([], thrice)).not_to have_key(:sub_threshold_duplicates)
    end

    it "reports it as a finding when the threshold is lowered" do
      config.n_plus_one_duplicate_threshold = 2

      expect(correlator.findings(observations: [], duplicates: twice).map(&:kind))
        .to include(:n_plus_one_pattern_match)
    end

    # A threshold of 1 would make a finding of every query an endpoint issues.
    it "refuses a threshold below two" do
      config.n_plus_one_duplicate_threshold = 1

      expect(correlator.findings(observations: [], duplicates: twice)).to be_empty
    end
  end
end
