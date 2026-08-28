# frozen_string_literal: true

require "loadwright/measurement"
require "loadwright/capability_profile"

module Loadwright
  module Analysis
    # Correlates query behaviour against what the response actually returned.
    #
    # THE CORRECTION THIS SUBSYSTEM EXISTS TO MAKE. discovery-and-load-engine.md
    # describes measuring query count against the SEEDED scale factor. That heuristic
    # has a blind spot: a properly paginated endpoint returns the same 25 records
    # whether you seed 10 rows or 10,000, so its query count is FLAT as seeded data
    # grows — and the slope looks perfect even when the endpoint has a severe N+1 on
    # the page it returns.
    #
    # So the N+1 slope is measured against RETURNED RECORD COUNT, and the load engine
    # sweeps page-size parameters to vary it. An endpoint whose returned count cannot
    # be varied at all reports the slope as Measurement.unavailable with that reason —
    # NEVER as flat/healthy. Whether that costs the endpoint its clean verdict is
    # decided by Coverage, not here: the slope is one of two N+1 detectors, and losing
    # one of two is reduced coverage rather than an unanswered question.
    #
    # Every signal here reads capability from CapabilityProfile and emits a
    # Measurement, so an unavailable signal is `unavailable(reason)` rather than absent
    # or zero. Nothing in this file may look at config.execution_mode.
    class ResponseCorrelator
      # A ratio at or below this is normal: one query for the collection plus a couple
      # for authorisation or a count.
      HEALTHY_RATIO = 3.0

      # Appended to a pattern-match finding whose repeat count did not move while the
      # returned record count did. Two different defects wear the same signature, and
      # the fix for one does nothing for the other.
      FIXED_REPEAT_DETAIL = " — and the query count did not grow with the number of records returned, " \
                            "so this is a fixed number of repeats per request rather than one per record"

      # The weaker denominator, labelled as such. See #scaling_against_seeded.
      SEEDED_FIXED_REPEAT_DETAIL = " — and the query count did not move across the seeded scale factors, " \
                                   "though the number of records returned could not be read from these " \
                                   "responses to confirm it"

      # THE DEFAULT REPORTING THRESHOLD for a repeated query, and the reason it is a
      # threshold rather than "any repeat": two identical queries in one request are
      # produced just as readily by two unrelated call sites as by a loop, and a finding
      # on every one of those would bury the real ones.
      #
      # Two is still waste, though, and this used to be the difference between a
      # finding and SILENCE -- an endpoint running the same query twice appeared in the
      # clean list with nothing to distinguish it from one that ran it once. Sub-
      # threshold repeats are now reported as an observation (see #duplicate_summary):
      # not a finding, not invisible either.
      DEFAULT_DUPLICATE_THRESHOLD = 3

      # Slope of queries against returned records. At 1.0 the endpoint issues one
      # query per record, which is the textbook N+1 signature. Well below that is
      # batching; the threshold sits low enough to catch a partial N+1 (an N+1 on one
      # association of several) without firing on a fixed handful of extra queries.
      N_PLUS_ONE_SLOPE = 0.5

      # `suggestion` is advisory and optional: the shape of a likely fix, or nil where
      # the query is not a shape we recognise. It never affects the outcome state or
      # the exit code -- see Analysis::FixSuggestion.
      Finding = Struct.new(:kind, :confidence, :detail, :evidence, :suggestion, keyword_init: true) do
        # over_fetch is a HINT and must never contribute to a non-zero exit code:
        # data is legitimately loaded for authorisation, filtering, and derived values
        # without being serialised. A tool that cries wolf about ordinary
        # authorisation queries gets uninstalled.
        def hint? = confidence == :low

        # compact: a finding with no recognised fix shape carries no `suggestion` key
        # at all, rather than a null that every renderer then has to guard.
        def to_h
          { kind: kind, confidence: confidence, detail: detail,
            evidence: evidence, suggestion: suggestion }.compact
        end
      end

      # One (returned_records, queries, bytes) observation, from one cell.
      Observation = Struct.new(:label, :records, :queries, :bytes, :seeded, :page_size, keyword_init: true) do
        def to_h
          { label: label, records: records, queries: queries, bytes: bytes, seeded: seeded, page_size: page_size }
        end
      end

      def initialize(config: Loadwright.configuration, capability:)
        @config = config
        @capability = capability
      end

      # --------------------------------------------------- queries per record

      def queries_per_record(observations)
        return unavailable(:queries_per_returned_record) unless available?(:queries_per_returned_record)

        usable = observations.select { |o| o.records.to_i.positive? && !o.queries.nil? }
        return Measurement.unavailable("no cell returned any records, so there is nothing to divide by") if usable.empty?

        ratios = usable.map { |o| o.queries.to_f / o.records }
        Measurement.value((ratios.sum / ratios.length).round(3))
      end

      # ------------------------------------------------------------- the slope

      # Measured against RETURNED records, which is the whole point. Returns a
      # Measurement of the slope, or unavailable with the reason — and "we could not
      # vary the result size" is a reason, not a zero.
      def n_plus_one_slope(observations)
        return unavailable(:n_plus_one_slope) unless available?(:n_plus_one_slope)

        usable = observations.reject { |o| o.records.nil? || o.queries.nil? }
        return Measurement.unavailable("no cell produced both a record count and a query count") if usable.length < 2

        record_counts = usable.map(&:records).uniq
        if record_counts.length < 2
          return Measurement.unavailable(
            "unable to vary result size — every cell returned #{record_counts.first} record(s) regardless of " \
            "seeding and page-size parameters, so the N+1 slope is not measurable. This is NOT a flat/healthy " \
            "result. Check that config.page_size_parameters matches the parameter this endpoint actually " \
            "accepts, or that the collection is large enough to paginate."
          )
        end

        Measurement.value(slope(usable.map(&:records), usable.map(&:queries)).round(4))
      end

      # ------------------------------------------------------- payload growth

      # Bytes against SEEDED rows, not returned records. This is the missing-pagination
      # signal, and no query-count signal will ever surface it: loading 10,000 records
      # can be a single efficient query.
      def payload_growth(observations)
        return unavailable(:payload_growth_pagination) unless available?(:payload_growth_pagination)

        usable = observations.reject { |o| o.seeded.nil? || o.bytes.nil? }
        return Measurement.unavailable("fewer than two seed scales produced a payload to compare") if usable.length < 2
        if usable.map(&:seeded).uniq.length < 2
          return Measurement.unavailable("only one seed scale was exercised, so payload growth is not measurable")
        end

        Measurement.value(correlation(usable.map(&:seeded), usable.map(&:bytes)).round(4))
      end

      # ------------------------------------------------------------- findings

      # `duplicates` is the per-request fingerprint tally from RequestMetrics;
      # `tables_queried` and `response_keys` drive the over-fetch hint.
      # `scaling_observations` is EVERY cell, where `observations` is the one sweep whose
      # question this call is answering.
      #
      # The two are different on purpose. The slope detector must see one sweep at a
      # time -- that is the entire point of holding one axis fixed in each. The
      # fixed/scaling classifier wants the opposite: as many axes as it can get,
      # because either one answers its question. Handing it the same narrowed set meant
      # that whenever the page-size sweep ran it saw only page-size cells, which all
      # share ONE seeded scale by construction -- so the seeded-scale fallback added
      # for exactly this case could never be reached, and the classifier abstained
      # while the report printed identical query counts across a hundredfold change in
      # seeded rows a few lines below.
      def findings(observations:, duplicates: {}, tables_queried: [], response_keys: [], max_bytes: nil,
                   scaling_observations: nil, duplicate_context: {})
        results = []

        results.concat(n_plus_one_findings(observations, duplicates, scaling_observations || observations,
                                           duplicate_context))
        results.concat(pagination_findings(observations, max_bytes))
        results.concat(over_fetch_findings(tables_queried, response_keys))

        results
      end

      # Which detectors could answer, in the shape Coverage consumes. Lives here
      # because this class owns the measurements — asking the load engine to re-derive
      # "was the slope available?" from a Measurement it also holds would be two
      # sources of truth for one fact.
      #
      # `explain` and `percentiles` are deliberately absent rather than reported
      # unavailable: ExplainAnalyzer and Statistics are not in this build, so those
      # detectors were never ATTEMPTED. Coverage treats an absent detector as
      # :not_applicable, which is reported but is not a gap this run caused. Reporting
      # them as unavailable would make every endpoint inconclusive until those
      # subsystems ship.
      def detector_states(observations:, query_data:, tables_queried: [], response_keys: [])
        slope = n_plus_one_slope(observations)
        growth = payload_growth(observations)

        {
          pattern_match: pattern_match_state(query_data),
          slope: slope.available? ? :available : [:unavailable, slope.reason],
          payload_growth: growth.available? ? :available : [:unavailable, growth.reason],
          query_response_comparison: over_fetch_state(tables_queried, response_keys)
        }
      end

      def to_h(observations, duplicates = {}, duplicate_context = {})
        {
          queries_per_returned_record: measurement_to_h(queries_per_record(observations)),
          n_plus_one_slope: measurement_to_h(n_plus_one_slope(observations)),
          payload_growth_correlation: measurement_to_h(payload_growth(observations)),
          sub_threshold_duplicates: duplicate_summary(duplicates, duplicate_context),
          observations: observations.map(&:to_h)
        }.compact
      end

      private

      # The pattern-match detector answers whenever query data came back at all: it can
      # then say "no fingerprint repeated", which is a genuine clean answer and covers
      # the N+1 class on its own. It only fails to answer when there were no queries to
      # inspect — an empty duplicates hash means "nothing repeated", not "nothing seen",
      # and conflating the two is how an uninstrumented run would report itself clean.
      def pattern_match_state(query_data)
        return :available if query_data

        [:unavailable,
         "no query data was collected for this endpoint, so duplicate query fingerprints could not be " \
         "inspected (see the collector in run metadata)"]
      end

      def over_fetch_state(tables_queried, response_keys)
        return nil unless @config.detect_overfetching

        unless available?(:over_fetch_hint)
          return [:unavailable, @capability.reason_for(:over_fetch_hint) || "over-fetch detection is unavailable"]
        end
        if tables_queried.empty?
          return [:unavailable, "no queried tables were recorded, so nothing could be compared to the response"]
        end

        :available
      end

      def available?(signal) = @capability.available?(signal) || @capability.partial?(signal)

      def unavailable(signal)
        Measurement.unavailable(@capability.reason_for(signal) || "#{signal} is unavailable")
      end

      public

      # NOT A FINDING, AND NOT INVISIBLE EITHER. A repeat below the reporting threshold
      # used to produce silence, so an endpoint issuing the same query twice per
      # request sat in the clean list looking identical to one that issued it once.
      # That is the same silence that let three endpoints move from a high-confidence
      # finding to "healthy" across four rounds with nothing to explain the transition.
      #
      # nil rather than an empty hash when there is nothing to say, so `.compact` drops
      # the key and a genuinely duplicate-free endpoint renders no row.
      def duplicate_summary(duplicates, duplicate_context = {})
        worst = duplicates.max_by { |_, occurrences| occurrences.length }
        return nil if worst.nil?
        return nil if worst.last.length >= duplicate_threshold

        context = duplicate_context[worst.first] || {}

        {
          fingerprint: worst.first,
          occurrences: worst.last.length,
          threshold: duplicate_threshold,
          queries_in_request: context[:queries],
          cell: context[:cell],
          note: "repeated queries were observed but not reported as a finding: the most repeated ran " \
                "#{worst.last.length} time(s) in a single request#{denominator_detail(context)}, under " \
                "the reporting threshold of #{duplicate_threshold}. Not nothing, and not a finding -- " \
                "lower n_plus_one_duplicate_threshold to see it as one."
        }.compact
      end

      private

      def measurement_to_h(measurement)
        measurement.available? ? { value: measurement.value } : { unavailable: measurement.reason }
      end

      def n_plus_one_findings(observations, duplicates, scaling_observations = observations,
                              duplicate_context = {})
        results = []

        # Signal 1 — pattern matching: duplicate fingerprints within one request, the
        # technique Bullet and Prosopite use.
        worst = duplicates.max_by { |_, occurrences| occurrences.length }
        if worst && worst.last.length >= duplicate_threshold
          scaling = repeat_scaling(scaling_observations)
          context = duplicate_context[worst.first] || {}
          results << Finding.new(
            kind: :n_plus_one_pattern_match,
            confidence: :high,
            detail: "the same query ran #{worst.last.length} times in a single request" \
                    "#{denominator_detail(context)}: #{worst.first}." \
                    "#{cache_detail(worst.last)}" \
                    "#{FIXED_REPEAT_DETAIL if scaling == :fixed}" \
                    "#{SEEDED_FIXED_REPEAT_DETAIL if scaling == :fixed_by_seed_scale}",
            evidence: { fingerprint: worst.first, occurrences: worst.last.length,
                        executed: worst.last.count { |query| !query[:cached] },
                        query_cache_hits: worst.last.count { |query| query[:cached] },
                        queries_in_request: context[:queries], cell: context[:cell],
                        scaling: scaling == :unknown ? nil : scaling,
                        call_site: worst.last.first[:call_site],
                        resolver: worst.last.first[:field_path] }.compact,
            suggestion: FixSuggestion.for(worst.first, repeats: worst.last.length, scaling: scaling)
          )
        end

        # Signal 2 — slope against returned records. Reported ALONGSIDE signal 1
        # rather than merged with it: they catch different failure modes, and
        # disagreement between them is itself informative.
        slope_measurement = n_plus_one_slope(observations)
        if slope_measurement.available? && slope_measurement.value >= N_PLUS_ONE_SLOPE
          results << Finding.new(
            kind: :n_plus_one_slope,
            confidence: :high,
            detail: "query count grows with the number of records returned " \
                    "(#{slope_measurement.value.round(2)} extra queries per additional record). " \
                    "This is the signature pagination hides from a seeded-scale measurement.",
            evidence: observations.map { |o| { records: o.records, queries: o.queries, page_size: o.page_size } }
          )
        end

        # NOTE: an unmeasurable slope emits NOTHING here, deliberately. It used to emit
        # a `confidence: :none` finding, which was a category error — "finding" says
        # something is wrong with the APP, when what is true is that a detector could
        # not answer. That belongs in the slope's own Measurement (which carries the
        # reason) and in Coverage, which is what the outcome state is derived from.
        # See response-analysis.md, "Outcome state is derived from coverage".

        results
      end

      # THE DENOMINATOR, NEXT TO THE NUMBER. A repeat count is only checkable against
      # the query count of the request it came from, and for five releases the two were
      # printed in different parts of the report -- a finding reading "ran 12 times in a
      # single request" sat above a cell table reporting 8 queries per request, and the
      # contradiction went unnoticed by everyone including us. Nothing enforces the
      # invariant here; putting the two numbers in one sentence is what lets a reader
      # enforce it.
      def denominator_detail(context)
        return "" if context[:queries].nil?

        " (of #{context[:queries].round} queries in that request, #{context[:cell]})"
      end

      # THE NUMBER A DEVELOPER REPRODUCES COLD IS NOT THE NUMBER WE REPORT, and the
      # gap between them is the query cache.
      #
      # A request that asks for the same row 21 times may execute 12 of them and have
      # 9 served from the request-level query cache. Both are true and they answer
      # different questions: 12 is what the database paid for, 21 is how many times
      # the code asked. A reader who reproduces the finding in a console -- where there
      # is no request wrapper and so no query cache -- sees the larger number and
      # concludes the tool is wrong. It cost one integration a full code trace to
      # establish that both of our numbers were right.
      #
      # The remedy is the same either way: stop asking for a row already in hand.
      def cache_detail(occurrences)
        cached = Array(occurrences).count { |query| query[:cached] }
        return "" if cached.zero?

        executed = Array(occurrences).length - cached

        " #{executed} executed and #{cached} served from the request query cache, so a cold " \
          "reproduction outside a request will show all #{Array(occurrences).length}."
      end

      # :fixed / :scaling / :unknown — what the run OBSERVED about how the repeat
      # behaves, never what it assumes.
      #
      # A per-record N+1 issues more queries as the endpoint returns more records. A
      # request that finds the same already-loaded row four times issues the same four
      # either way. The two are indistinguishable from a single request's fingerprints
      # and trivially distinguishable across cells, which is data this run already has.
      #
      # :unknown wherever the comparison is not available -- fewer than two cells, or
      # every cell returning the same number of records. Flatness that was never
      # measured is not flatness.
      # Never below 2: "the same query ran once" is not a repeat, and a threshold of 1
      # would make a finding of every query an endpoint issues.
      def duplicate_threshold
        value = @config.n_plus_one_duplicate_threshold
        value.to_i < 2 ? DEFAULT_DUPLICATE_THRESHOLD : value.to_i
      rescue StandardError
        DEFAULT_DUPLICATE_THRESHOLD
      end

      def repeat_scaling(observations)
        usable = Array(observations).reject { |o| o.records.nil? || o.queries.nil? }
        if usable.length >= 2 && usable.map(&:records).uniq.length >= 2
          return usable.map(&:queries).uniq.length == 1 ? :fixed : :scaling
        end

        scaling_against_seeded(observations)
      end

      # THE AXIS WE STILL HAVE. Returned record count is the right denominator and it
      # is not always available -- an endpoint that answers with a single object has no
      # record count to read, and on an API made mostly of detail endpoints the
      # classifier had no input at all and abstained on every finding. Abstaining was
      # correct. Having nothing else to ask was a gap.
      #
      # Seeded scale is a weaker denominator and a real one: a query count identical at
      # seed scale 1 and seed scale 100 did not move while the data underneath it moved
      # a hundredfold.
      #
      # It gets its OWN value rather than being folded into :fixed, because it rests on
      # an assumption :fixed does not. A paginated collection returns the same page
      # whatever the seeded scale, so flatness here is exactly what a per-record N+1
      # behind pagination looks like -- the blind spot the page-size sweep exists for.
      # The suggestion names that assumption instead of hiding it.
      def scaling_against_seeded(observations)
        usable = Array(observations).reject { |o| o.seeded.nil? || o.queries.nil? }
        return :unknown if usable.length < 2
        return :unknown if usable.map(&:seeded).uniq.length < 2

        usable.map(&:queries).uniq.length == 1 ? :fixed_by_seed_scale : :scaling
      end

      def pagination_findings(observations, max_bytes)
        results = []
        growth = payload_growth(observations)
        threshold = @config.payload_growth_correlation_threshold

        if growth.available? && growth.value >= threshold
          results << Finding.new(
            kind: :missing_pagination,
            confidence: :high,
            detail: "response size grows with the number of rows in the table " \
                    "(correlation #{growth.value.round(2)} against seeded scale). The endpoint returns an " \
                    "unbounded collection. Note the query count may be perfectly flat — one query can load " \
                    "ten thousand rows.",
            evidence: observations.map { |o| { seeded: o.seeded, bytes: o.bytes, records: o.records } }
          )
        end

        largest = observations.map(&:bytes).compact.max
        limit = max_bytes || @config.max_response_bytes_warning
        if largest && largest > limit
          results << Finding.new(
            kind: :oversized_payload,
            confidence: :high,
            detail: "largest response was #{(largest / 1024.0).round(1)} KB, over the " \
                    "#{(limit / 1024.0).round(1)} KB max_response_bytes_warning threshold",
            evidence: { largest_bytes: largest, threshold_bytes: limit }
          )
        end

        results
      end

      # A HINT, always. Data is legitimately loaded for authorisation, for filtering,
      # for computing a derived value, and for callbacks. Phrased as "worth checking",
      # never as a defect, and never contributing to an exit code.
      def over_fetch_findings(tables_queried, response_keys)
        return [] unless @config.detect_overfetching
        return [] unless available?(:over_fetch_hint)
        return [] if tables_queried.empty? || response_keys.empty?

        keys = response_keys.map { |key| key.to_s.downcase }
        unused = tables_queried.map(&:to_s).uniq.reject do |table|
          singular = table.sub(/s\z/, "")
          keys.any? { |key| key.include?(singular) || singular.include?(key.sub(/_id\z/, "")) }
        end

        return [] if unused.empty?

        [Finding.new(
          kind: :over_fetch_hint,
          confidence: :low,
          detail: "queried #{unused.join(', ')} but nothing from #{unused.length == 1 ? 'it' : 'them'} appears " \
                  "in the response — worth checking whether the eager load is needed. This is a hint, not a " \
                  "defect: data is legitimately loaded for authorisation, filtering, and derived values " \
                  "without being serialised.",
          evidence: { tables_queried: tables_queried.uniq, response_keys: response_keys.uniq, unused: unused }
        )]
      end

      # Least-squares slope. Deliberately plain: with three to five points, a fitted
      # curve would be reading structure into noise, and the question is only "does
      # this grow with that".
      def slope(xs, ys)
        n = xs.length
        mean_x = xs.sum.to_f / n
        mean_y = ys.sum.to_f / n
        denominator = xs.sum { |x| (x - mean_x)**2 }
        return 0.0 if denominator.zero?

        xs.each_with_index.sum { |x, i| (x - mean_x) * (ys[i] - mean_y) } / denominator
      end

      # Pearson correlation, for "does payload size track table size" where the
      # magnitude of the slope is meaningless (bytes per row varies per endpoint) but
      # the tightness of the relationship is the signal.
      def correlation(xs, ys)
        n = xs.length
        mean_x = xs.sum.to_f / n
        mean_y = ys.sum.to_f / n
        covariance = xs.each_with_index.sum { |x, i| (x - mean_x) * (ys[i] - mean_y) }
        variance_x = Math.sqrt(xs.sum { |x| (x - mean_x)**2 })
        variance_y = Math.sqrt(ys.sum { |y| (y - mean_y)**2 })
        return 0.0 if variance_x.zero? || variance_y.zero?

        covariance / (variance_x * variance_y)
      end
    end
  end
end
