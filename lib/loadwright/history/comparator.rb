# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/analysis/statistics"
require "loadwright/capability_profile"

module Loadwright
  module History
    # "Did my change make it worse?" -- the question developers actually ask.
    #
    # TWO THINGS GOVERN THIS CLASS, and both are about refusing to mislead.
    #
    # 1. THE COMPARABILITY GATE. Two runs are comparable only where their measurement
    #    conditions match. If they do not, we refuse and NAME THE DIMENSION that
    #    diverged. Comparing concurrency 20 to concurrency 5, or :http to :in_process,
    #    produces numbers that look meaningful and are not -- and a plausible-looking
    #    meaningless delta is worse than no comparison, because it gets acted on.
    #
    #    The gate has three parts, and the second and third are the ones easily missed:
    #
    #      a. Resolved config, not assigned config. Two runs with identical explicit
    #         settings but different contention presets resolve to different timeouts
    #         and are not comparable. Configuration fingerprints resolved values
    #         already; this compares the resolved values themselves so the refusal can
    #         say WHICH key differs rather than only that the digests do.
    #
    #      b. CAPABILITY, not just config. A run that degraded mid-way and lost query
    #         collection has the same config fingerprint and dramatically less data.
    #         The INTERSECTION of the two runs' capabilities is what is comparable;
    #         anything outside it is excluded from the delta and listed, never silently
    #         compared against a missing number.
    #
    #      c. The app's own default page size. The seed-scale sweep sends no page-size
    #         parameter, so what it holds fixed is an app property invisible to the
    #         config fingerprint. A change to it is treated exactly like a change to
    #         page_size_sweep.
    #
    # 2. QUERY COUNTS ARE THE SIGNAL; LATENCY IS MOSTLY NOISE. An endpoint that went
    #    from 3 queries to 47 has unambiguously regressed, reproducibly, on any
    #    machine. Laptop latency moves 10-20% between identical runs, so a latency
    #    delta must clear BOTH regression_threshold_pct AND the measured noise floor
    #    before it is called a regression. Everything below those bars is shown and
    #    labelled "within noise" -- a comparison tool that cries wolf is ignored inside
    #    a week.
    class Comparator
      # EVERY COMPARED METRIC APPEARS HERE, and the value is either the capability it
      # depends on or NO_CAPABILITY_REQUIRED. There is no default and no nil: a metric
      # compared without an entry raises, because the failure this table prevents is
      # a metric being compared against a hole and reported as "no change".
      #
      # `nil` used to mean both "needs nothing" and "nobody decided yet", which is how
      # `records` sat here for a whole milestone with no delta implemented at all.
      # The sentinel forces the question to be answered rather than skipped.
      NO_CAPABILITY_REQUIRED = :none

      SIGNAL_REQUIREMENTS = {
        # Query data comes from the app's own instrumentation, and the External
        # collector cannot retrieve any of it. All the query-derived signals go
        # unavailable together, so any one of them stands for the group.
        queries: :n_plus_one_pattern_match,

        # Response-derived, all three of them: measured from the bytes that came back,
        # so every collector has them, including External against a remote target.
        # `latency_ms` deliberately does NOT depend on :true_client_latency -- that
        # signal is unavailable under :in_process, but an in-process run's latency is
        # still perfectly comparable to another in-process run's, and the config gate
        # has already refused a cross-mode comparison.
        records: NO_CAPABILITY_REQUIRED,
        bytes: NO_CAPABILITY_REQUIRED,
        latency_ms: NO_CAPABILITY_REQUIRED
      }.freeze

      # NOT COMPARED, and deliberately so: allocations are not persisted per cell, so
      # there is nothing to compare. This is why :clean_memory_attribution appears in
      # no requirement above. Adding an allocation delta means persisting the figure
      # first, and gating it on that capability when it is.
      UNCOMPARED_SIGNALS = %i[clean_memory_attribution].freeze

      # Query counts are near-deterministic, so the tolerance exists only to absorb a
      # genuinely incidental difference (a cache warming one query earlier). Anything
      # above it is reported.
      COUNT_TOLERANCE = 0

      # Payload size moves a little with ids and timestamps, so it gets a small
      # proportional tolerance rather than an absolute one.
      BYTES_TOLERANCE = 0.05

      # Below this, a latency change is not even worth listing as within-noise.
      # run-comparison.md wants noise SHOWN rather than hidden, but a row reading
      # "p50 latency: 100.0 -> 100.0, within noise" is not information -- it is padding
      # that buries the rows that matter. Anything under 5% is agreed by every reading
      # to have not moved.
      LATENCY_REPORTING_FLOOR = 0.05

      # AND an absolute floor. A percentage computed on sub-millisecond values is
      # unstable in the same way a ratio between two tiny numbers is: 0.63ms -> 0.89ms
      # is "42% slower" and is also 0.26ms, which is scheduler noise. Local endpoints
      # against a small dev database live in exactly that range, so without this the
      # threshold fires on jitter for every fast endpoint -- and a comparison tool that
      # cries wolf is ignored within a week.
      #
      # Nothing is lost by it: a change too small to clear this is, by construction,
      # too small to notice, and a genuine regression that matters shows up in the
      # query count, which needs no threshold at all.
      LATENCY_ABSOLUTE_FLOOR_MS = 1.0

      Divergence = Struct.new(:dimension, :before, :after, keyword_init: true) do
        def to_h = { dimension: dimension, before: before, after: after }

        def to_s = "#{dimension}: #{before.inspect} -> #{after.inspect}"
      end

      Delta = Struct.new(:endpoint, :metric, :before, :after, :change, :verdict, :note,
                         keyword_init: true) do
        def regression? = verdict == :regression

        def improvement? = verdict == :improvement

        def within_noise? = verdict == :within_noise

        # Real, worth seeing, and carrying no verdict: the basis for comparing it
        # changed underneath. Rendered in its own section rather than filed as either
        # a regression or an improvement.
        def unattributable? = verdict == :unattributable

        def to_h
          { endpoint: endpoint, metric: metric, before: before, after: after,
            change: change&.round(4), verdict: verdict, note: note }.compact
        end
      end

      Transition = Struct.new(:endpoint, :before, :after, :note, keyword_init: true) do
        def to_h = { endpoint: endpoint, before: before, after: after, note: note }
      end

      Result = Struct.new(:comparable, :divergences, :warnings, :new_findings, :resolved_findings,
                          :changed_findings, :deltas, :transitions, :endpoints_added,
                          :endpoints_removed, :excluded_signals, :noise_floor, :noise_floor_source,
                          keyword_init: true) do
        def comparable? = comparable == true

        def regressions = deltas.select(&:regression?)

        def within_noise = deltas.select(&:within_noise?)

        def unattributable = deltas.select(&:unattributable?)

        # A new finding is a regression; so is a query-count rise. Resolved findings are
        # deliberately NOT netted against them -- a fix and a regression in one run are
        # two facts, not zero.
        def regressed? = new_findings.any? || regressions.any?

        # THE SIGNATURE OF A BUSIER MACHINE, NAMED RATHER THAN LEFT TO THE READER.
        #
        # A real slowdown moves query counts, or moves latency on the endpoints that
        # changed. What it does not do is push p50 up by a similar amount on every
        # endpoint at once, including ones that touch no database -- that is the
        # laptop, and the tool's own rule already says query deltas are the primary
        # signal because they are near-deterministic and latency is not.
        #
        # This does NOT change the verdict or the exit code. It is a heuristic, and a
        # heuristic that silently downgraded a regression would be the same class of
        # error as reporting one that is not there. It says what the shape looks like
        # and leaves the call to the reader -- which is what was missing: the evidence
        # was all present and nothing assembled it into a sentence.
        MACHINE_NOISE_MINIMUM_ENDPOINTS = 3

        def machine_noise_signature?
          return false if new_findings.any?

          # The metric reads "p50 latency (<cell shape>)", so this matches on the word
          # rather than a prefix -- a prefix check silently matched nothing, which would
          # have made this diagnosis dead code that always answered false.
          latency = regressions.select { |delta| delta.metric.to_s.include?("latency") }
          return false unless latency.length == regressions.length
          return false if latency.empty?

          latency.map(&:endpoint).uniq.length >= MACHINE_NOISE_MINIMUM_ENDPOINTS &&
            latency.all? { |delta| delta.change.to_f.positive? }
        end

        def machine_noise_note
          return nil unless machine_noise_signature?

          endpoints = regressions.map(&:endpoint).uniq.length

          "Every regression here is latency, every one is in the same direction, and they are spread " \
            "across #{endpoints} unrelated endpoints with no query-count movement anywhere. That is the " \
            "signature of a busier machine rather than a code change. Query counts are the " \
            "near-deterministic signal; treat these as suspect until a re-run reproduces them, and set " \
            "a baseline on this commit so the noise floor is measured rather than assumed."
        end

        def refusal
          return nil if comparable?

          "these runs are not comparable: #{divergences.map(&:to_s).join('; ')}"
        end

        def to_h
          {
            comparable: comparable?,
            refusal: refusal,
            divergences: divergences.map(&:to_h),
            warnings: warnings,
            new_findings: new_findings,
            resolved_findings: resolved_findings,
            changed_findings: changed_findings,
            regressions: regressions.map(&:to_h),
            within_noise: within_noise.map(&:to_h),
            machine_noise_note: machine_noise_note,
            transitions: transitions.map(&:to_h),
            endpoints_added: endpoints_added,
            endpoints_removed: endpoints_removed,
            excluded_signals: excluded_signals,
            noise_floor: noise_floor,
            noise_floor_source: noise_floor_source
          }.compact
        end
      end

      def initialize(config: Loadwright.configuration, statistics: nil)
        @config = config
        @statistics = statistics || Analysis::Statistics.new(config: config)
      end

      def compare(before, after, noise_floor: nil, noise_floor_source: nil)
        divergences = hard_divergences(before, after)
        return refused(divergences) if divergences.any?

        excluded = excluded_signals(before, after)
        shared = before.endpoint_keys & after.endpoint_keys

        Result.new(
          comparable: true,
          divergences: [],
          warnings: soft_warnings(before, after),
          new_findings: findings_diff(before, after, shared, :new),
          resolved_findings: findings_diff(before, after, shared, :resolved),
          changed_findings: changed_findings(before, after, shared),
          deltas: deltas(before, after, shared, excluded, noise_floor),
          transitions: transitions(before, after, shared),
          endpoints_added: after.endpoint_keys - before.endpoint_keys,
          endpoints_removed: before.endpoint_keys - after.endpoint_keys,
          excluded_signals: excluded,
          noise_floor: noise_floor,
          noise_floor_source: noise_floor_source
        )
      end

      # ------------------------------------------------------------------ the gate

      # Divergences that make a comparison meaningless rather than merely caveated.
      def hard_divergences(before, after)
        divergences = version_divergences(before, after)
        divergences.concat(config_divergences(before, after))
        divergences.concat(page_size_divergences(before, after))
        divergences
      end

      # THE TOOL ITSELF IS A DIMENSION, and leaving it out let the worst reading in.
      #
      # `resolved_for` exists to stop a disappeared finding being reported as a fix
      # when nothing was measured. It watches the endpoint's state and misses the other
      # door entirely: the detector changing underneath two runs.
      #
      # This is not hypothetical. Between two releases the pattern-match repeat count
      # went from a sum across cells to the per-request figure it had always claimed to
      # be. An endpoint reporting "the same query ran 4 times" under the old counting
      # had a true per-request repeat of 2 -- below the reporting threshold -- so it
      # correctly stopped being a finding. Compare those two runs and the answer comes
      # back "resolved: n_plus_one_pattern_match": your fix worked, on an application
      # nobody had touched.
      #
      # A HARD divergence, not a caveat. Thresholds move, detectors are added, a
      # measurement's meaning changes -- and the tool cannot know which of its own
      # releases were semantically neutral. Failing closed costs one re-run of the
      # baseline on the current version; failing open costs somebody a day chasing a
      # fix they already made, or worse, believing one they never made.
      def version_divergences(before, after)
        mine = tool_version(before)
        theirs = tool_version(after)
        return [] if mine.nil? || theirs.nil? || mine == theirs

        [Divergence.new(dimension: "loadwright_version", before: mine, after: theirs)]
      end

      def tool_version(record)
        value = record.respond_to?(:data) ? record.data.dig("metadata", "loadwright_version") : nil
        value&.to_s
      end

      def config_divergences(before, after)
        Configuration::COMPARABILITY_KEYS.filter_map do |key|
          mine = comparability_value(before, key)
          theirs = comparability_value(after, key)
          next if mine == theirs

          Divergence.new(dimension: "config.#{key}", before: mine, after: theirs)
        end
      end

      # THE DIMENSION THAT IS NOT IN THE CONFIG FINGERPRINT. The seed-scale sweep sends
      # no page-size parameter, so the axis it holds fixed is whatever the APP defaults
      # to -- a property of the app, not of the run. Two runs either side of a change to
      # that default are not comparing the same thing even though both fingerprints
      # match, so a change here is treated exactly like a change to page_size_sweep.
      def page_size_divergences(before, after)
        mine = observed_page_sizes(before)
        theirs = observed_page_sizes(after)

        (mine.keys & theirs.keys).filter_map do |endpoint|
          next if mine[endpoint] == theirs[endpoint]

          Divergence.new(dimension: "#{endpoint} observed default page size",
                         before: mine[endpoint], after: theirs[endpoint])
        end
      end

      # CAPABILITY, NOT JUST CONFIG. Two runs with identical config are not comparable
      # on query counts if one of them lost query collection partway. Rather than
      # refusing the whole comparison -- run-comparison.md prefers a partial comparison
      # on the intersection -- the affected metrics are excluded and named.
      def excluded_signals(before, after)
        mine = effective_capabilities(before)
        theirs = effective_capabilities(after)

        SIGNAL_REQUIREMENTS.filter_map do |metric, signal|
          next if signal == NO_CAPABILITY_REQUIRED
          next if available?(mine, signal) && available?(theirs, signal)

          missing = available?(mine, signal) ? "the later run" : "the earlier run"
          { metric: metric, signal: signal, detail: "#{signal} was unavailable in #{missing}, so " \
                                                    "#{metric} cannot be compared and is excluded " \
                                                    "from this delta" }
        end
      end

      # Softer mismatches: reported, never a refusal.
      def soft_warnings(before, after)
        warnings = []

        if before.fingerprint != after.fingerprint
          # Named precisely. An earlier version of this line promised "allocation
          # deltas", which are not computed at all -- allocations are not persisted
          # per cell. Naming a comparison the report does not contain tells the reader
          # their memory usage was checked when nothing checked it.
          warnings << "these runs were measured on different machines or Ruby/database versions. " \
                      "Query, record-count and payload deltas are still reliable; LATENCY deltas are " \
                      "not, and are labelled within-noise more readily as a result."
        end

        [[before, "earlier"], [after, "later"]].each do |record, which|
          warnings << "the #{which} run was made from a dirty worktree, so its git SHA does not fully " \
                      "describe the code that produced it" if record.dirty?
        end

        [[before, "earlier"], [after, "later"]].each do |record, which|
          warnings << "the #{which} run was aborted partway, so it covers fewer endpoints than it " \
                      "intended to" if record.aborted?
        end

        added = after.endpoint_keys - before.endpoint_keys
        removed = before.endpoint_keys - after.endpoint_keys
        if added.any? || removed.any?
          warnings << "the endpoint sets differ; the intersection was compared. " \
                      "Added: #{added.empty? ? 'none' : added.join(', ')}. " \
                      "Removed: #{removed.empty? ? 'none' : removed.join(', ')}."
        end

        warnings
      end

      # -------------------------------------------------------------- findings & state

      def findings_diff(before, after, shared, direction)
        shared.flat_map do |key|
          old_kinds = finding_kinds(before, key)
          new_kinds = finding_kinds(after, key)

          case direction
          when :new then (new_kinds - old_kinds).map { |kind| { endpoint: key, finding: kind } }
          when :resolved then resolved_for(before, after, key, old_kinds - new_kinds)
          end
        end
      end

      # A FINDING THAT DISAPPEARED BECAUSE THE ENDPOINT STOPPED BEING MEASURABLE IS NOT
      # A FIX. This is the failure this method exists to prevent: an endpoint that went
      # from `has_findings` to `inconclusive` has lost its findings in the arithmetic,
      # and reporting that as "resolved: N+1" tells a developer their fix worked when
      # nothing was even checked.
      def resolved_for(_before, after, key, disappeared)
        state = endpoint_state(after, key)

        disappeared.map do |kind|
          if state == "inconclusive"
            { endpoint: key, finding: kind, resolved: false,
              note: "this finding is absent because the endpoint became INCONCLUSIVE, not because it " \
                    "was fixed -- nothing was measured to fix. See its transition below." }
          else
            { endpoint: key, finding: kind, resolved: true }
          end
        end
      end

      def changed_findings(before, after, shared)
        shared.flat_map do |key|
          old = findings_by_kind(before, key)
          new = findings_by_kind(after, key)

          (old.keys & new.keys).filter_map do |kind|
            next if old[kind]["detail"] == new[kind]["detail"]

            { endpoint: key, finding: kind, before: old[kind]["detail"], after: new[kind]["detail"] }
          end
        end
      end

      # A state change is its own event. healthy -> inconclusive has neither improved
      # nor regressed: it became unmeasurable, which is worth surfacing on its own terms
      # rather than being inferred from findings appearing or vanishing.
      def transitions(before, after, shared)
        shared.filter_map do |key|
          old_state = endpoint_state(before, key)
          new_state = endpoint_state(after, key)
          next if old_state == new_state || old_state.nil? || new_state.nil?

          Transition.new(endpoint: key, before: old_state, after: new_state,
                         note: transition_note(old_state, new_state, after, key))
        end
      end

      def transition_note(old_state, new_state, after, key)
        return nil unless new_state == "inconclusive"

        reason = after.endpoint(key)&.dig("reason")
        "became unmeasurable (#{reason || 'reason not recorded'}). This is neither an improvement nor a " \
          "regression, and any findings it no longer reports were not fixed -- they were not looked for."
      end

      # ------------------------------------------------------------------- the deltas

      def deltas(before, after, shared, excluded, noise_floor)
        excluded_metrics = excluded.map { |entry| entry[:metric] }

        shared.flat_map do |key|
          old_cells = cells_by_shape(before, key)
          new_cells = cells_by_shape(after, key)
          question_changed = request_changed(before, after, key)

          (old_cells.keys & new_cells.keys).flat_map do |shape|
            compare_cell(key, shape, old_cells[shape], new_cells[shape], excluded_metrics, noise_floor,
                         question_changed)
          end
        end.compact
      end

      # THE TWO RUNS ASKED THIS ENDPOINT DIFFERENT QUESTIONS.
      #
      # The denominator rule above says a query count is never compared without its
      # record count. This is the same rule one level out: a query count is not
      # comparable across two runs that sent different parameters either.
      #
      # It is not hypothetical. An endpoint measured at 73 queries and 250ms in one run
      # came back HEALTHY in the next, because a changed recording meant it was no
      # longer sent the parameter that selects its expensive representation. Nothing in
      # either report said the question had changed, so a confirmed defect un-found
      # itself and the comparison would have called it a large improvement.
      #
      # Returns a description of what differed, or nil. nil also covers "cannot tell":
      # a run record written before request shapes were persisted carries none, and
      # inventing a difference from a missing field would strip verdicts off every
      # delta in a comparison against any older baseline.
      def request_changed(before, after, key)
        old_shape = request_shape(before, key)
        new_shape = request_shape(after, key)
        return nil if old_shape.nil? || new_shape.nil?

        old_params = Hash(old_shape["query"]).keys.sort
        new_params = Hash(new_shape["query"]).keys.sort
        return nil if old_params == new_params

        added = new_params - old_params
        removed = old_params - new_params
        [
          removed.any? ? "no longer sends #{removed.join(', ')}" : nil,
          added.any? ? "now sends #{added.join(', ')}" : nil
        ].compact.join(" and ")
      end

      def request_shape(record, key)
        endpoint = record.respond_to?(:endpoint) ? record.endpoint(key) : nil
        shape = endpoint && endpoint["request"]
        shape.is_a?(Hash) ? shape : nil
      end

      def compare_cell(key, shape, old_cell, new_cell, excluded_metrics, noise_floor, question_changed = nil)
        deltas = []
        # A changed question strips the verdict off exactly what a changed denominator
        # does, and for the same reason: the number is real and its direction means
        # nothing.
        records_moved = records_moved?(old_cell, new_cell) || !question_changed.nil?

        if comparable?(:queries, excluded_metrics)
          deltas << count_delta(key, shape, :queries, old_cell["queries"], new_cell["queries"],
                                records_moved: records_moved, question_changed: question_changed)
        end
        deltas << records_delta(key, shape, old_cell["records"], new_cell["records"]) if
          comparable?(:records, excluded_metrics)
        deltas << bytes_delta(key, shape, old_cell["bytes"], new_cell["bytes"]) if
          comparable?(:bytes, excluded_metrics)
        deltas << latency_delta(key, shape, old_cell, new_cell, noise_floor) if
          comparable?(:latency_ms, excluded_metrics)

        deltas.compact
      end

      # Raises rather than defaulting. A metric compared without a SIGNAL_REQUIREMENTS
      # entry has had no capability decision made about it, and the safe-looking
      # default -- compare it anyway -- is precisely the bug this gate exists to stop.
      def comparable?(metric, excluded_metrics)
        unless SIGNAL_REQUIREMENTS.key?(metric)
          raise ArgumentError,
                "#{metric.inspect} is compared but has no SIGNAL_REQUIREMENTS entry. Add the " \
                "capability it depends on, or NO_CAPABILITY_REQUIRED with the reason it needs none."
        end

        !excluded_metrics.include?(metric)
      end

      # THE DENOMINATOR MOVED. A query count means nothing on its own -- it means
      # something next to the number of records that produced it.
      #
      # Every cell has carried a `records` figure since the engine was built; it was
      # simply never compared. The result was the most flattering wrong answer a
      # comparison tool can give: narrow a scope, break a filter, or ship a bug that
      # makes a collection return 5 records instead of 30, and queries fall 31 -> 6.
      # Reported as an improvement, that tells a developer their N+1 is fixed when
      # what actually happened is that their endpoint stopped returning data.
      #
      # Absent on BOTH sides is not "moved" -- error responses carry no record count,
      # and neither do records written before the field existed. Stripping the verdict
      # from those would gut the comparison for every older run.
      def records_moved?(old_cell, new_cell)
        before = old_cell["records"]
        after = new_cell["records"]
        return false if before.nil? || after.nil?

        before != after
      end

      # NO STATISTICAL TREATMENT, deliberately. A query count is close to deterministic:
      # 3 -> 47 is unambiguous, reproducible on any machine, in any mode, under any
      # load. Applying a noise threshold to it would only ever hide a real regression.
      def count_delta(key, shape, metric, before, after, records_moved: false, question_changed: nil)
        return nil if before.nil? || after.nil?
        return nil if (after - before).abs <= COUNT_TOLERANCE

        Delta.new(
          endpoint: key, metric: "#{metric} (#{shape})", before: before, after: after,
          change: before.zero? ? nil : (after - before) / before.to_f,
          verdict: verdict_for_count(after, before, records_moved),
          note: count_note(after, before, records_moved, question_changed)
        )
      end

      # SHOWN, but without a verdict the denominator cannot support. Neither
      # :regression nor :improvement -- the number is real and worth seeing, and the
      # only honest reading of it is alongside the record count that changed under it.
      def verdict_for_count(after, before, records_moved)
        return :unattributable if records_moved

        after > before ? :regression : :improvement
      end

      def count_note(after, before, records_moved, question_changed = nil)
        if question_changed
          return "this run #{question_changed}, so the two runs asked this endpoint different " \
                 "questions and the change is not attributable to the app. An endpoint whose cost " \
                 "depends on a parameter is only as well measured as the parameters it was sent."
        end

        if records_moved
          return "the number of records returned changed too, so this is not a like-for-like " \
                 "comparison — see the returned-records row for the same cell"
        end

        "query count is near-deterministic; this is a real change, not noise" if after > before
      end

      # A COLLECTION THAT STOPPED RETURNING THINGS is a regression in its own right,
      # and the strongest version of the case above. Growth is reported without a
      # verdict: more records is not itself better or worse, and at an unchanged scale
      # factor it usually means the app's own default page size moved.
      def records_delta(key, shape, before, after)
        return nil if before.nil? || after.nil? || before == after

        Delta.new(
          endpoint: key, metric: "returned records (#{shape})", before: before, after: after,
          change: before.zero? ? nil : (after - before) / before.to_f,
          verdict: after < before ? :regression : :unattributable,
          note: if after < before
                  "the endpoint returned fewer records at the same scale factor and page size. " \
                  "A narrowed scope or a broken filter looks exactly like this, and it makes any " \
                  "query-count drop for this cell meaningless."
                else
                  "the endpoint returned more records at the same scale factor and page size, " \
                  "usually because its own default or maximum page size moved. More records is " \
                  "neither better nor worse, but any query-count rise for this cell is explained " \
                  "by it rather than by an N+1."
                end
        )
      end

      def bytes_delta(key, shape, before, after)
        return nil if before.nil? || after.nil? || before.zero?

        change = (after - before) / before.to_f
        return nil if change.abs <= BYTES_TOLERANCE

        Delta.new(endpoint: key, metric: "payload bytes (#{shape})", before: before, after: after,
                  change: change, verdict: change.positive? ? :regression : :improvement)
      end

      # BOTH BARS. run-comparison.md: the threshold alone produces false alarms
      # constantly, because laptop latency moves 10-20% between identical runs. The
      # measured noise floor is what turns the threshold from a guess into a
      # measurement of THIS machine.
      def latency_delta(key, shape, old_cell, new_cell, noise_floor)
        before = old_cell.dig("latency_ms", "p50")
        after = new_cell.dig("latency_ms", "p50")
        return nil if before.nil? || after.nil? || before.zero?

        change = (after - before) / before.to_f
        return nil if change.abs < LATENCY_REPORTING_FLOOR

        moved_enough = (after - before).abs >= LATENCY_ABSOLUTE_FLOOR_MS
        regression = moved_enough && @statistics.latency_regression?(before, after, noise_floor: noise_floor)
        bar = @statistics.bar(noise_floor)

        Delta.new(
          endpoint: key, metric: "p50 latency (#{shape})",
          # ROUNDED. A raw float renders as 0.6289997100830078 in a table, which is
          # both unreadable and falsely precise about a figure this class has just
          # finished explaining is noisy.
          before: before.round(2), after: after.round(2), change: change,
          verdict: regression ? :regression : :within_noise,
          note: regression ? nil : noise_note(change, bar, noise_floor, moved_enough: moved_enough)
        )
      end

      def noise_note(change, bar, noise_floor, moved_enough: true)
        unless moved_enough
          return "within noise: #{(change * 100).round}% change, but under " \
                 "#{LATENCY_ABSOLUTE_FLOOR_MS}ms in absolute terms. A percentage on sub-millisecond " \
                 "values is jitter wearing a decimal point; the query count is the signal to read."
        end

        measured = noise_floor.respond_to?(:value_or) ? noise_floor.value_or(nil) : noise_floor
        basis = if measured && measured > (@config.regression_threshold_pct.to_f / 100.0)
                  "a noise floor of #{(measured * 100).round}% measured on this machine"
                else
                  "the configured regression_threshold_pct of #{@config.regression_threshold_pct}%"
                end

        "within noise: #{(change * 100).round}% change against #{basis} " \
          "(bar: #{(bar * 100).round}%). Shown because you may want to see it, not reported as a regression."
      end

      # ------------------------------------------------------------------ record access

      def comparability_value(record, key)
        record.metadata.dig("config", key.to_s, "value")
      end

      def observed_page_sizes(record)
        record.metadata.dig("sweeps", "seed_scale", "observed_page_size") || {}
      end

      # The capability actually in effect at the END of the run, which is the most
      # degraded it ever was. A run that lost query collection at request 200 cannot be
      # compared on query counts, however capable it started out.
      def effective_capabilities(record)
        epochs = record.metadata.dig("capabilities", "epochs")
        return {} if epochs.nil? || epochs.empty?

        epochs.last["capabilities"] || {}
      end

      def available?(capabilities, signal)
        # Absent means the run predates the field or did not record it. Treated as
        # available so an older record is comparable rather than silently excluded --
        # the config gate has already established the runs match in every dimension we
        # can see.
        entry = capabilities[signal.to_s]
        entry.nil? || entry["status"] == "available"
      end

      def endpoint_state(record, key) = record.endpoint(key)&.dig("state")

      def finding_kinds(record, key)
        Array(record.endpoint(key)&.dig("findings")).filter_map { |finding| finding["kind"] }
      end

      def findings_by_kind(record, key)
        Array(record.endpoint(key)&.dig("findings")).to_h { |finding| [finding["kind"], finding] }
      end

      # Cells are matched by SHAPE -- sweep, scale, page size, concurrency -- not by
      # position. Position matching would silently pair a concurrency-1 cell with a
      # concurrency-5 one the moment an endpoint was added or a level skipped.
      def cells_by_shape(record, key)
        Array(record.data["cells"])
          .select { |cell| cell["endpoint"] == key }
          .to_h do |cell|
            shape = "#{cell['sweep']} scale=#{cell['scale_factor']} " \
                    "page=#{cell['page_size'] || 'default'} c=#{cell['requested_concurrency']}"
            [shape, cell]
          end
      end

      def refused(divergences)
        Result.new(
          comparable: false, divergences: divergences, warnings: [], new_findings: [],
          resolved_findings: [], changed_findings: [], deltas: [], transitions: [],
          endpoints_added: [], endpoints_removed: [], excluded_signals: []
        )
      end
    end
  end
end
