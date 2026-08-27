# frozen_string_literal: true

RSpec.describe Loadwright::History::Comparator do
  let(:config) { Loadwright::Configuration.new }

  subject(:comparator) { described_class.new(config: config) }

  # Records are built as the data they are on disk -- string keys, JSON shapes -- rather
  # than round-tripped through RunStore, so a comparison bug cannot hide behind a
  # serialisation bug.
  def record(endpoints: nil, cells: nil, config_overrides: {}, machine: nil, git: nil,
             capabilities: nil, page_sizes: nil, aborted: false, version: "9.9.9")
    snapshot = Loadwright::Configuration::COMPARABILITY_KEYS.to_h do |key|
      [key.to_s, { "value" => config_overrides.fetch(key, config.public_send(key)), "from" => "default" }]
    end

    Loadwright::History::RunStore::Record.new(
      run_id: "r#{object_id}", path: "/dev/null",
      data: {
        "metadata" => {
          "loadwright_version" => version,
          "config" => snapshot,
          "machine" => machine || { "cpu_count" => 8, "os" => "darwin", "ruby_version" => "3.3.0" },
          "git" => git || { "sha" => "abc123", "dirty" => false },
          "capabilities" => capabilities,
          "sweeps" => { "seed_scale" => { "observed_page_size" => page_sizes || {} } },
          "aborted" => aborted
        },
        "endpoints" => endpoints || [],
        "cells" => cells || []
      }
    )
  end

  def endpoint(key, state: "healthy", findings: [], reason: nil, query: nil)
    { "endpoint" => key, "state" => state, "reason" => reason,
      "request" => query && { "path" => key, "query" => query },
      "findings" => findings.map { |f| f.is_a?(Hash) ? f : { "kind" => f.to_s } } }.compact
  end

  def cell(key, queries: 3, latency: 100.0, bytes: 1_000, concurrency: 1, records: nil)
    { "endpoint" => key, "sweep" => "seed_scale", "scale_factor" => 10, "page_size" => nil,
      "requested_concurrency" => concurrency, "queries" => queries, "bytes" => bytes,
      "records" => records, "latency_ms" => { "p50" => latency } }
  end

  # THE COMPARABILITY GATE. A plausible-looking meaningless delta is worse than no
  # comparison, because it gets acted on.
  describe "the comparability gate" do
    it "refuses two runs at different concurrency levels" do
      result = comparator.compare(record, record(config_overrides: { concurrency_levels: [1, 20] }))

      expect(result).not_to be_comparable
      expect(result.refusal).to include("config.concurrency_levels")
    end

    it "refuses an :http run compared against an :in_process one" do
      result = comparator.compare(record, record(config_overrides: { execution_mode: :http }))

      expect(result.refusal).to include("config.execution_mode")
    end

    it "names the diverging dimension and both values, not just that they differ" do
      result = comparator.compare(record, record(config_overrides: { scale_factors: [1, 2] }))

      expect(result.refusal).to include("scale_factors", "[1, 2]")
    end

    # The fingerprint is over RESOLVED values, and a preset changes resolved values
    # without changing a single explicit assignment. Two runs with identical explicit
    # config and different presets are not comparable.
    it "refuses runs whose containment resolved differently, however they were assigned" do
      result = comparator.compare(record, record(config_overrides: { block_outbound_http: false }))

      expect(result.refusal).to include("config.block_outbound_http")
    end

    # THE DIMENSION THAT IS NOT IN THE CONFIG FINGERPRINT. The seed-scale sweep sends no
    # page-size parameter, so what it holds fixed is the APP's default -- a property of
    # the app, not the run. Both fingerprints match and the runs still measure different
    # things.
    it "refuses when the app's own default page size changed underneath the run" do
      before = record(page_sizes: { "GET /a" => 25 })
      after = record(page_sizes: { "GET /a" => 50 })

      result = comparator.compare(before, after)

      expect(result).not_to be_comparable
      expect(result.refusal).to include("observed default page size", "25", "50")
    end

    it "compares happily when the observed page size held steady" do
      before = record(page_sizes: { "GET /a" => 25 })
      after = record(page_sizes: { "GET /a" => 25 })

      expect(comparator.compare(before, after)).to be_comparable
    end
  end

  # CAPABILITY, NOT JUST CONFIG. Two runs with identical config are not comparable on
  # query counts if one of them lost query collection partway. Rather than refusing
  # outright, the affected metric is EXCLUDED and named.
  describe "the capability intersection" do
    def degraded_capabilities
      timeline = Loadwright::CapabilityTimeline.new(
        Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware)
      )
      timeline.degrade!(:n_plus_one_pattern_match, reason: "the collector stopped answering")
      JSON.parse(JSON.generate(timeline.to_h))
    end

    def full_capabilities
      JSON.parse(JSON.generate(
                   Loadwright::CapabilityTimeline.new(
                     Loadwright::CapabilityProfile.derive(transport: :http, collector: :middleware)
                   ).to_h
                 ))
    end

    it "excludes query counts when one run lost query collection mid-way" do
      before = record(capabilities: full_capabilities, cells: [cell("GET /a", queries: 3)],
                      endpoints: [endpoint("GET /a")])
      after = record(capabilities: degraded_capabilities, cells: [cell("GET /a", queries: 47)],
                     endpoints: [endpoint("GET /a")])

      result = comparator.compare(before, after)

      expect(result).to be_comparable
      expect(result.excluded_signals.map { |s| s[:metric] }).to include(:queries)
    end

    # Silently comparing 3 against a missing number would report "no change", which is
    # the confidently-wrong answer this whole design exists to prevent.
    it "reports no query delta at all rather than comparing against a hole" do
      before = record(capabilities: full_capabilities, cells: [cell("GET /a", queries: 3)],
                      endpoints: [endpoint("GET /a")])
      after = record(capabilities: degraded_capabilities, cells: [cell("GET /a", queries: 47)],
                     endpoints: [endpoint("GET /a")])

      result = comparator.compare(before, after)

      expect(result.deltas.map(&:metric).join).not_to include("queries")
    end

    it "says which run lost the capability, so the reader knows which side to fix" do
      before = record(capabilities: full_capabilities)
      after = record(capabilities: degraded_capabilities)

      expect(comparator.compare(before, after).excluded_signals.first[:detail])
        .to include("the later run")
    end

    it "compares queries normally when both runs kept the capability" do
      before = record(capabilities: full_capabilities, cells: [cell("GET /a", queries: 3)],
                      endpoints: [endpoint("GET /a")])
      after = record(capabilities: full_capabilities, cells: [cell("GET /a", queries: 47)],
                     endpoints: [endpoint("GET /a")])

      expect(comparator.compare(before, after).regressions.map(&:metric).join).to include("queries")
    end
  end

  # THE TABLE THAT DECIDES WHAT IS COMPARABLE. It sat with three nil entries for a
  # whole milestone, and nil meant two different things: "needs no capability" and
  # "nobody has decided yet". `records` was in the second category -- persisted by
  # every cell, listed here, and compared by nothing at all.
  #
  # These examples exist so the next metric cannot be added the same way.
  describe "the capability requirements table" do
    it "gives every compared metric an explicit answer, never nil" do
      expect(described_class::SIGNAL_REQUIREMENTS.values).to all(be_a(Symbol))
    end

    it "names only capabilities that actually exist" do
      gated = described_class::SIGNAL_REQUIREMENTS.values
                                                  .reject { |v| v == described_class::NO_CAPABILITY_REQUIRED }

      expect(gated - Loadwright::CapabilityProfile::SIGNALS).to be_empty
    end

    # The raise is the point. Comparing an unlisted metric anyway -- the convenient
    # default -- is exactly the hole the table exists to close.
    it "refuses to compare a metric it has no entry for" do
      expect { comparator.send(:comparable?, :allocations, []) }
        .to raise_error(ArgumentError, /no SIGNAL_REQUIREMENTS entry/)
    end

    # Documented as uncompared rather than silently absent, so the next reader knows
    # it was a decision and what unblocks it.
    it "records which capabilities are deliberately not compared, and why" do
      expect(described_class::UNCOMPARED_SIGNALS).to include(:clean_memory_attribution)
      expect(described_class::UNCOMPARED_SIGNALS)
        .to all(satisfy { |signal| Loadwright::CapabilityProfile::SIGNALS.include?(signal) })
    end

    it "does not gate a metric on a capability it does not actually need" do
      # Latency under :in_process is real and comparable to another :in_process run,
      # even though :true_client_latency is unavailable there. Gating it would exclude
      # every in-process comparison the tool makes by default.
      expect(described_class::SIGNAL_REQUIREMENTS[:latency_ms])
        .to eq(described_class::NO_CAPABILITY_REQUIRED)
    end
  end

  # THE DENOMINATOR. A query count only means something next to the number of
  # records that produced it, and every cell has carried a `records` figure all
  # along -- it was simply never compared.
  #
  # The failure this prevents is the most flattering one a comparison tool can
  # produce: a developer narrows a scope, breaks a filter, or ships a bug that makes
  # a collection endpoint return five records instead of thirty. Queries fall 31 ->
  # 6 and the report says "improvement". It is not an improvement. It is the same
  # queries-per-record over less data, and the endpoint is arguably broken.
  describe "a query count whose record count moved underneath it" do
    it "does not call a proportional query drop an improvement" do
      before = record(cells: [cell("GET /a", queries: 31, records: 30)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 6, records: 5)], endpoints: [endpoint("GET /a")])

      result = comparator.compare(before, after)
      queries = result.deltas.find { |d| d.metric.start_with?("queries") }

      expect(queries).not_to be_improvement
      expect(queries.note).to include("records")
    end

    # Still SHOWN. run-comparison.md wants the number visible; what it must not carry
    # is a verdict the denominator does not support.
    it "still reports the query change, without a verdict it cannot support" do
      before = record(cells: [cell("GET /a", queries: 31, records: 30)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 6, records: 5)], endpoints: [endpoint("GET /a")])

      queries = comparator.compare(before, after).deltas.find { |d| d.metric.start_with?("queries") }

      expect(queries.before).to eq(31)
      expect(queries.after).to eq(6)
      expect(queries).not_to be_regression
    end

    # The mirror image, and the more dangerous direction: MORE records and more
    # queries is not automatically an N+1 regression either.
    it "does not call a query rise a regression when more records were returned" do
      before = record(cells: [cell("GET /a", queries: 6, records: 5)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 31, records: 30)], endpoints: [endpoint("GET /a")])

      queries = comparator.compare(before, after).deltas.find { |d| d.metric.start_with?("queries") }

      expect(queries).not_to be_regression
    end

    # The real regression must survive all of this: same records, more queries.
    it "still calls a query rise at an unchanged record count a regression" do
      before = record(cells: [cell("GET /a", queries: 3, records: 30)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 47, records: 30)], endpoints: [endpoint("GET /a")])

      queries = comparator.compare(before, after).deltas.find { |d| d.metric.start_with?("queries") }

      expect(queries).to be_regression
    end

    # Older records, and error responses, carry no record count at all. Absent is not
    # "changed" -- treating it as such would strip the verdict off every comparison
    # against a run written before the field existed.
    it "compares normally when neither run recorded a record count" do
      before = record(cells: [cell("GET /a", queries: 3, records: nil)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 47, records: nil)], endpoints: [endpoint("GET /a")])

      queries = comparator.compare(before, after).deltas.find { |d| d.metric.start_with?("queries") }

      expect(queries).to be_regression
    end

    # Growth carries no verdict -- more records is neither better nor worse -- but it
    # still has to say why the cell is not comparable, or it renders as a bare row
    # with an empty reason in a section whose entire purpose is giving reasons.
    it "explains a record-count increase rather than leaving the reason blank" do
      before = record(cells: [cell("GET /a", queries: 6, records: 5)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 31, records: 30)], endpoints: [endpoint("GET /a")])

      records = comparator.compare(before, after).deltas.find { |d| d.metric.start_with?("returned records") }

      expect(records).to be_unattributable
      expect(records.note).to include("page size")
    end

    it "reports the record count change in its own right" do
      before = record(cells: [cell("GET /a", queries: 31, records: 30)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 6, records: 5)], endpoints: [endpoint("GET /a")])

      records = comparator.compare(before, after).deltas.find { |d| d.metric.start_with?("returned records") }

      expect(records).not_to be_nil
      expect(records.before).to eq(30)
      expect(records.after).to eq(5)
    end

    # An endpoint that stopped returning anything is the strongest version of this,
    # and it must not be filed as a win.
    it "treats a collapse to zero records as a regression, not a query improvement" do
      before = record(cells: [cell("GET /a", queries: 31, records: 30)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 1, records: 0)], endpoints: [endpoint("GET /a")])

      result = comparator.compare(before, after)
      records = result.deltas.find { |d| d.metric.start_with?("returned records") }

      expect(records).to be_regression
      expect(result).to be_regressed
    end
  end

  # QUERY COUNTS ARE THE SIGNAL. Near-deterministic, reproducible on any machine.
  describe "query count deltas" do
    it "reports 3 -> 47 as a regression, with no statistical treatment" do
      before = record(cells: [cell("GET /a", queries: 3)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 47)], endpoints: [endpoint("GET /a")])

      delta = comparator.compare(before, after).regressions.first

      expect(delta.before).to eq(3)
      expect(delta.after).to eq(47)
      expect(delta.note).to include("near-deterministic")
    end

    it "reports a drop as an improvement rather than ignoring it" do
      before = record(cells: [cell("GET /a", queries: 47)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 3)], endpoints: [endpoint("GET /a")])

      expect(comparator.compare(before, after).deltas.map(&:verdict)).to include(:improvement)
    end

    it "says nothing when the count held steady" do
      before = record(cells: [cell("GET /a", queries: 3)], endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 3)], endpoints: [endpoint("GET /a")])

      expect(comparator.compare(before, after).deltas.map(&:metric).join).not_to include("queries")
    end

    # Position matching would pair a concurrency-1 cell with a concurrency-5 one the
    # moment an endpoint was added or a level skipped.
    it "matches cells by shape, not by position" do
      before = record(cells: [cell("GET /a", queries: 3, concurrency: 1),
                              cell("GET /a", queries: 30, concurrency: 5)],
                      endpoints: [endpoint("GET /a")])
      after = record(cells: [cell("GET /a", queries: 30, concurrency: 5),
                             cell("GET /a", queries: 3, concurrency: 1)],
                     endpoints: [endpoint("GET /a")])

      expect(comparator.compare(before, after).deltas).to be_empty
    end
  end

  # LATENCY IS MOSTLY NOISE. A tool that cries wolf gets ignored within a week.
  describe "latency deltas" do
    def latency_result(before_ms, after_ms, noise_floor: nil)
      comparator.compare(
        record(cells: [cell("GET /a", latency: before_ms)], endpoints: [endpoint("GET /a")]),
        record(cells: [cell("GET /a", latency: after_ms)], endpoints: [endpoint("GET /a")]),
        noise_floor: noise_floor
      )
    end

    # A row reading "100.0 -> 100.0, within noise" is padding that buries the rows
    # that matter.
    it "does not list a change too small to be worth showing at all" do
      expect(latency_result(100.0, 101.0).deltas).to be_empty
    end

    it "calls a 15% rise within noise, not a regression" do
      delta = latency_result(100.0, 115.0).deltas.find { |d| d.metric.include?("latency") }

      expect(delta).to be_within_noise
      expect(delta.note).to include("within noise")
    end

    it "still SHOWS it, because the developer may want to see it" do
      result = latency_result(100.0, 115.0)

      expect(result.within_noise).not_to be_empty
      expect(result.regressions).to be_empty
    end

    it "calls a 40% rise a regression once it clears the configured threshold" do
      expect(latency_result(100.0, 140.0).regressions.map(&:metric).join).to include("latency")
    end

    # A PERCENTAGE ON SUB-MILLISECOND VALUES IS JITTER WEARING A DECIMAL POINT.
    # 0.65ms -> 0.91ms is "40% slower" and is also a quarter of a millisecond. Local
    # endpoints against a small dev database live in exactly that range, so without an
    # absolute floor the threshold fires on scheduler noise for every fast endpoint.
    it "does not call a sub-millisecond move a regression, however large the percentage" do
      result = latency_result(0.65, 0.91)

      expect(result.regressions).to be_empty
      expect(result.within_noise.first.note).to include("jitter wearing a decimal point")
    end

    it "still calls a large absolute move a regression" do
      expect(latency_result(10.0, 40.0).regressions).not_to be_empty
    end

    it "rounds the figures it reports, rather than printing a raw float" do
      delta = latency_result(0.6289997100830078, 0.8940000534057617).deltas.first

      expect(delta.before).to eq(0.63)
      expect(delta.after).to eq(0.89)
    end

    # BOTH BARS. Without the measured floor, regression_threshold_pct is a guess about
    # what this machine's jitter looks like.
    it "raises the bar when this machine's measured noise floor exceeds the threshold" do
      floor = Loadwright::Measurement.value(0.5)

      expect(latency_result(100.0, 140.0, noise_floor: floor).regressions).to be_empty
    end

    it "says which bar it applied, so the number is not just dismissed silently" do
      floor = Loadwright::Measurement.value(0.5)
      delta = latency_result(100.0, 140.0, noise_floor: floor).within_noise.first

      expect(delta.note).to include("50% measured on this machine")
    end

    it "never lowers the bar below the configured threshold on a quiet machine" do
      floor = Loadwright::Measurement.value(0.01)

      expect(latency_result(100.0, 115.0, noise_floor: floor).regressions).to be_empty
    end
  end

  describe "findings" do
    it "reports a finding present in the later run and not the earlier one" do
      before = record(endpoints: [endpoint("GET /a")])
      after = record(endpoints: [endpoint("GET /a", state: "has_findings", findings: [:n_plus_one_slope])])

      expect(comparator.compare(before, after).new_findings)
        .to eq([{ endpoint: "GET /a", finding: "n_plus_one_slope" }])
    end

    it "reports a fix, which is how a developer confirms the change worked" do
      before = record(endpoints: [endpoint("GET /a", state: "has_findings", findings: [:n_plus_one_slope])])
      after = record(endpoints: [endpoint("GET /a")])

      resolved = comparator.compare(before, after).resolved_findings.first

      expect(resolved[:finding]).to eq("n_plus_one_slope")
      expect(resolved[:resolved]).to be(true)
    end

    it "reports the same finding at a different magnitude" do
      before = record(endpoints: [endpoint("GET /a", state: "has_findings",
                                           findings: [{ "kind" => "n_plus_one_slope", "detail" => "3x" }])])
      after = record(endpoints: [endpoint("GET /a", state: "has_findings",
                                          findings: [{ "kind" => "n_plus_one_slope", "detail" => "9x" }])])

      expect(comparator.compare(before, after).changed_findings.first)
        .to include(finding: "n_plus_one_slope", before: "3x", after: "9x")
    end
  end

  # THE TRANSITION THAT MUST NOT READ AS A FIX. An endpoint that went from
  # has_findings to inconclusive lost its findings in the arithmetic. Reporting that as
  # "resolved" tells a developer their fix worked when nothing was even checked.
  describe "state transitions" do
    let(:before) do
      record(endpoints: [endpoint("GET /a", state: "has_findings", findings: [:n_plus_one_slope])])
    end
    let(:after) do
      record(endpoints: [endpoint("GET /a", state: "inconclusive", reason: "unsuccessful_status")])
    end

    it "refuses to call a disappeared finding fixed when the endpoint stopped being measurable" do
      resolved = comparator.compare(before, after).resolved_findings.first

      expect(resolved[:resolved]).to be(false)
      expect(resolved[:note]).to include("not because it was fixed")
    end

    it "surfaces the transition as its own event, neither improvement nor regression" do
      transition = comparator.compare(before, after).transitions.first

      expect(transition.before).to eq("has_findings")
      expect(transition.after).to eq("inconclusive")
      expect(transition.note).to include("neither an improvement nor a regression")
    end

    it "names why it became unmeasurable, since that is the actionable part" do
      expect(comparator.compare(before, after).transitions.first.note).to include("unsuccessful_status")
    end

    it "reports a healthy -> inconclusive move too, where no finding disappeared at all" do
      healthy = record(endpoints: [endpoint("GET /a")])
      unmeasurable = record(endpoints: [endpoint("GET /a", state: "inconclusive", reason: "auth_failed")])

      expect(comparator.compare(healthy, unmeasurable).transitions.first.after).to eq("inconclusive")
    end
  end

  describe "softer mismatches, which warn rather than refuse" do
    it "warns that latency is unreliable across machines but query counts are not" do
      after = record(machine: { "cpu_count" => 2, "os" => "linux", "ruby_version" => "3.3.0" })

      warning = comparator.compare(record, after).warnings.find { |w| w.include?("different machines") }

      expect(warning).to include("still reliable")
      expect(warning).to include("LATENCY deltas are not")
    end

    # This line used to promise "allocation deltas", which the comparator does not
    # compute -- allocations are not persisted per cell. Naming a comparison the
    # report does not contain tells a reader their memory was checked when nothing
    # checked it, which is the same confidently-wrong shape as the rest of this file.
    it "promises no comparison it does not actually perform" do
      after = record(machine: { "cpu_count" => 2, "os" => "linux", "ruby_version" => "3.3.0" })

      warning = comparator.compare(record, after).warnings.find { |w| w.include?("different machines") }

      expect(warning).not_to include("allocation")
    end

    it "warns about a dirty worktree on either side" do
      dirty = record(git: { "sha" => "abc123", "dirty" => true })

      expect(comparator.compare(record, dirty).warnings.join).to include("later run was made from a dirty")
    end

    it "warns about an aborted run covering fewer endpoints than it intended" do
      expect(comparator.compare(record, record(aborted: true)).warnings.join)
        .to include("was aborted partway")
    end

    # Silently dropping them would make an endpoint that stopped being discovered look
    # like an endpoint that stopped having problems.
    it "compares the intersection and lists what was added and removed" do
      before = record(endpoints: [endpoint("GET /a"), endpoint("GET /gone")])
      after = record(endpoints: [endpoint("GET /a"), endpoint("GET /new")])

      result = comparator.compare(before, after)

      expect(result.endpoints_added).to eq(["GET /new"])
      expect(result.endpoints_removed).to eq(["GET /gone"])
      expect(result.warnings.join).to include("endpoint sets differ")
    end
  end

  describe "#regressed?" do
    it "is true when a new finding appeared" do
      after = record(endpoints: [endpoint("GET /a", state: "has_findings", findings: [:n_plus_one_slope])])

      expect(comparator.compare(record(endpoints: [endpoint("GET /a")]), after)).to be_regressed
    end

    # A fix and a regression in one run are two facts, not zero.
    it "is still true when something was also fixed" do
      before = record(endpoints: [endpoint("GET /a", state: "has_findings", findings: [:missing_pagination]),
                                  endpoint("GET /b")])
      after = record(endpoints: [endpoint("GET /a"),
                                 endpoint("GET /b", state: "has_findings", findings: [:n_plus_one_slope])])

      expect(comparator.compare(before, after)).to be_regressed
    end

    it "is false for two identical runs" do
      expect(comparator.compare(record(endpoints: [endpoint("GET /a")]),
                                record(endpoints: [endpoint("GET /a")]))).not_to be_regressed
    end
  end
  # THE TWO RUNS ASKED THIS ENDPOINT DIFFERENT QUESTIONS. The denominator rule says a
  # query count is never compared without its record count; this is the same rule one
  # level out. An endpoint measured at 73 queries came back HEALTHY in the next run
  # because a changed recording stopped sending the parameter that selects its
  # expensive representation -- and the comparison would have called that a large
  # improvement.
  describe "an endpoint sent different parameters between runs" do
    def comparison_for(before_query, after_query)
      before = record(endpoints: [endpoint("GET /a", query: before_query)],
                      cells: [cell("GET /a", queries: 73)])
      after = record(endpoints: [endpoint("GET /a", query: after_query)],
                     cells: [cell("GET /a", queries: 6)])

      comparator.compare(before, after)
    end

    it "strips the verdict off the query delta rather than calling it an improvement" do
      delta = comparison_for({ "view" => "recorded" }, {}).deltas.find { |d| d.metric.start_with?("queries") }

      expect(delta.verdict).to eq(:unattributable)
    end

    it "names what changed, so the reader can see which question moved" do
      delta = comparison_for({ "view" => "recorded" }, {}).deltas.find { |d| d.metric.start_with?("queries") }

      expect(delta.note).to include("no longer sends view")
    end

    it "names a parameter that appeared as well as one that vanished" do
      delta = comparison_for({ "view" => "recorded" }, { "expand" => "recorded" })
                .deltas.find { |d| d.metric.start_with?("queries") }

      expect(delta.note).to include("no longer sends view").and include("now sends expand")
    end

    it "compares normally when both runs asked the same question" do
      delta = comparison_for({ "view" => "recorded" }, { "view" => "recorded" })
              .deltas.find { |d| d.metric.start_with?("queries") }

      expect(delta.verdict).to eq(:improvement)
    end

    # A record written before request shapes were persisted carries none, and
    # inventing a difference from a missing field would strip the verdict off every
    # delta in a comparison against any older baseline.
    it "compares normally against a baseline that predates request shapes" do
      delta = comparison_for(nil, { "view" => "recorded" })
              .deltas.find { |d| d.metric.start_with?("queries") }

      expect(delta.verdict).to eq(:improvement)
    end
  end
  # THE TOOL ITSELF IS A DIMENSION. `resolved_for` already refuses to call a finding
  # fixed when the endpoint stopped being measurable -- and it watched the endpoint's
  # state while missing the other door: the detector changing underneath two runs.
  #
  # Between two releases the pattern-match repeat count went from a sum across cells
  # to the per-request figure it had always claimed to be. An endpoint reporting "the
  # same query ran 4 times" under the old counting had a true repeat of 2, below the
  # reporting threshold, so it correctly stopped being a finding. Comparing those two
  # runs answers "resolved" -- your fix worked, on an application nobody touched.
  describe "two runs measured by different versions of the tool" do
    let(:before) do
      record(version: "0.0.4", endpoints: [endpoint("GET /a", state: "has_findings",
                                                    findings: [:n_plus_one_pattern_match])],
             cells: [cell("GET /a", queries: 8)])
    end

    let(:after) do
      record(version: "0.0.5", endpoints: [endpoint("GET /a")], cells: [cell("GET /a", queries: 8)])
    end

    it "refuses rather than reporting a fix nobody made" do
      expect(comparator.compare(before, after)).not_to be_comparable
    end

    it "names the version as the dimension that moved" do
      divergence = comparator.compare(before, after).divergences.first

      expect(divergence.dimension).to eq("loadwright_version")
      expect([divergence.before, divergence.after]).to eq(%w[0.0.4 0.0.5])
    end

    it "computes no deltas and claims nothing resolved" do
      comparison = comparator.compare(before, after)

      expect(comparison.deltas).to be_empty
      expect(comparison.resolved_findings).to be_empty
    end

    it "compares normally when both runs came from the same version" do
      same = record(version: "0.0.4", endpoints: [endpoint("GET /a")], cells: [cell("GET /a", queries: 8)])

      expect(comparator.compare(before, same)).to be_comparable
    end

    # A record written before the version was persisted carries none, and inventing a
    # divergence from a missing field would refuse every comparison against an older
    # baseline.
    it "compares normally when a record predates the version being recorded" do
      older = record(version: nil, endpoints: [endpoint("GET /a")], cells: [cell("GET /a", queries: 8)])

      expect(comparator.compare(older, after)).to be_comparable
    end
  end
end
