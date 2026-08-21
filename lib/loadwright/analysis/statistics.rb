# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/measurement"

module Loadwright
  module Analysis
    # Percentiles, sample counts, and dispersion — with the percentiles the sample
    # size cannot support OMITTED rather than printed.
    #
    # WHY THIS IS A SUBSYSTEM AND NOT A ONE-LINER. `sorted[(n * 0.99).round]` on 25
    # samples returns the 25th-largest of 25, which is the maximum wearing a decimal
    # point. A report that prints "p99: 412ms" from that has invented a number, and
    # invented numbers are this tool's defining failure mode — the same category as a
    # 403 reported as fast. So every percentile is a Measurement: available with a
    # value, or unavailable with the sample size it would need.
    #
    # WHAT COUNTS AS ONE SAMPLE POPULATION. Statistics are computed per CELL, not per
    # endpoint. A cell holds one scale factor, one page size, and one concurrency
    # level, so its latencies are draws from one distribution. Pooling an endpoint's
    # concurrency-1 and concurrency-20 requests would produce a median describing
    # neither, and the wider spread would then be read as noise.
    #
    # THE BUDGET IS CHECKED AGAINST THE HIGHEST SUPPORTED PERCENTILE, and the report
    # says which one that was. p95_latency_budget_ms names p95, and at the default 25
    # requests per cell p95 is not supported — so refusing to check anything would
    # make the latency class permanently unanswerable at default settings, which is
    # the coverage-flooding failure the three-state model exists to prevent. Checking
    # p50 against a p95 budget is sound in the direction that matters: a median above
    # the p95 budget is unambiguously over budget, and it is a STRONGER finding than
    # the one asked for, not a weaker one. The converse is stated rather than implied
    # — a p50 within budget does not clear p95, and #budget_check says so.
    class Statistics
      # Order matters: lowest requirement first, so #best_supported walks it in one
      # pass and #summarize reports omissions in a stable order.
      PERCENTILES = { p50: 0.50, p95: 0.95, p99: 0.99 }.freeze

      # Below this, dispersion is not a statistic, it is two numbers.
      MIN_SAMPLES_FOR_DISPERSION = 3

      # A coefficient of variation above this means the mean is being dragged around
      # by outliers and any latency comparison against this cell is unreliable.
      # Reported, never used to suppress a measurement.
      HIGH_VARIANCE_CV = 0.5

      Summary = Struct.new(:label, :sample_count, :min, :median, :max, :mean, :stddev,
                           :coefficient_of_variation, :percentiles, keyword_init: true) do
        # The highest percentile the sample size actually supported, or nil when even
        # the lowest was not supported.
        def best_supported
          PERCENTILES.keys.reverse.find { |name| percentiles[name]&.available? }
        end

        def supported?(name) = percentiles[name]&.available? || false

        def omitted = percentiles.select { |_, m| m.unavailable? }.transform_values(&:reason)

        def high_variance?
          coefficient_of_variation.available? && coefficient_of_variation.value > HIGH_VARIANCE_CV
        end

        def to_h
          {
            label: label,
            sample_count: sample_count,
            min_ms: min&.round(3),
            median_ms: median&.round(3),
            max_ms: max&.round(3),
            mean_ms: mean&.round(3),
            stddev_ms: stddev&.round(3),
            # Serialised as the tri-state, never as a bare number: an omitted percentile
            # must not render as "—" beside a real one.
            coefficient_of_variation: measurement_to_h(coefficient_of_variation),
            high_variance: high_variance?,
            percentiles: percentiles.transform_values { |m| measurement_to_h(m) },
            best_supported: best_supported
          }.compact
        end

        private

        def measurement_to_h(measurement)
          measurement.available? ? { value: measurement.value } : { unavailable: measurement.reason }
        end
      end

      # A latency budget verdict. `checked_at` names the percentile actually used, so
      # a reader is never left guessing whether the number they are looking at is the
      # one the budget describes.
      BudgetCheck = Struct.new(:budget_ms, :checked_at, :observed_ms, :exceeded, :caveat,
                               keyword_init: true) do
        def exceeded? = exceeded == true

        def to_h
          { budget_ms: budget_ms, checked_at: checked_at, observed_ms: observed_ms&.round(3),
            exceeded: exceeded, caveat: caveat }.compact
        end
      end

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      # How many samples a percentile needs before it is reported at all.
      def required_samples(name)
        configured = @config.min_samples_for_percentiles
        configured[name] || configured[name.to_s] ||
          raise(ArgumentError, "no minimum sample count configured for #{name.inspect}")
      end

      def supported?(name, sample_count) = sample_count >= required_samples(name)

      # THE ENTRY POINT. `values` is one homogeneous population — one cell's latencies.
      def summarize(values, label: nil)
        usable = Array(values).compact.map(&:to_f).sort
        count = usable.length

        Summary.new(
          label: label,
          sample_count: count,
          min: usable.first,
          median: count.zero? ? nil : quantile(usable, 0.5),
          max: usable.last,
          mean: count.zero? ? nil : usable.sum / count,
          stddev: standard_deviation(usable),
          coefficient_of_variation: coefficient_of_variation(usable),
          percentiles: PERCENTILES.to_h { |name, fraction| [name, percentile(usable, name, fraction)] }
        )
      end

      # Coverage state for the `percentiles` detector.
      #
      # The class is covered once the LOWEST configured percentile is supported by at
      # least one cell: at that point we can make a defensible statement about the
      # endpoint's latency, even if not at the precision the budget names. Below it we
      # have a handful of timings and nothing to say, and the fix is a config change
      # the reason states outright.
      def detector_state(summaries)
        summaries = Array(summaries)
        return [:unavailable, "no latency samples were collected for this endpoint"] if summaries.empty?

        return :available if summaries.any? { |summary| summary.best_supported }

        best = summaries.map(&:sample_count).max.to_i
        lowest = PERCENTILES.keys.first
        [:unavailable,
         "the largest sample for this endpoint was #{best} request(s); #{lowest} needs " \
         "#{required_samples(lowest)}. Raise requests_per_endpoint_per_level."]
      end

      # Checks the budget against the best percentile the sample supports, and records
      # which one that was plus what it does not prove.
      def budget_check(summary, budget_ms)
        return nil if budget_ms.nil?

        name = summary.best_supported
        return nil if name.nil?

        observed = summary.percentiles.fetch(name).value

        BudgetCheck.new(
          budget_ms: budget_ms,
          checked_at: name,
          observed_ms: observed,
          exceeded: observed > budget_ms,
          caveat: caveat_for(name, summary)
        )
      end

      # The budget key for an endpoint: an exact match first, then :default.
      # p95_latency_budget_ms is a hash so a slow-by-nature endpoint can be given its
      # own allowance rather than the whole run being loosened for it.
      def budget_for(endpoint_key)
        budgets = @config.p95_latency_budget_ms
        return nil unless budgets.is_a?(Hash)

        budgets[endpoint_key] || budgets[endpoint_key.to_s] || budgets[:default] || budgets["default"]
      end

      # ------------------------------------------------------------------ noise floor
      #
      # Used by the run comparator. run-comparison.md is emphatic that laptop latency
      # moves 10-20% between identical runs, so a latency delta must clear BOTH the
      # configured threshold and the observed run-to-run variance before it is called
      # a regression. This is where the second half of that lives.

      # The relative spread observed between two runs of the same commit, expressed as
      # a fraction. `loadwright baseline set` records it; without one, the caller
      # falls back to the configured threshold alone and must say so.
      def noise_floor_from(paired_values)
        pairs = Array(paired_values).reject { |a, b| a.nil? || b.nil? || a.to_f.zero? }
        return Measurement.unavailable("no paired baseline runs; the noise floor is unmeasured") if pairs.empty?

        deltas = pairs.map { |a, b| ((b.to_f - a.to_f) / a.to_f).abs }
        Measurement.value(deltas.max)
      end

      # A latency change is a regression only if it clears the configured threshold AND
      # the measured noise floor. Returns the bar it had to clear, so the report can say
      # "12% change, within a measured 18% noise floor" rather than just hiding it.
      def latency_regression?(before, after, noise_floor: nil)
        return false if before.nil? || after.nil? || before.to_f.zero?

        change = (after.to_f - before.to_f) / before.to_f
        change > bar(noise_floor)
      end

      def bar(noise_floor)
        configured = @config.regression_threshold_pct.to_f / 100.0
        measured = noise_floor.respond_to?(:value_or) ? noise_floor.value_or(nil) : noise_floor

        [configured, measured].compact.max
      end

      private

      # A percentile the sample cannot support is unavailable WITH THE NUMBER IT WOULD
      # NEED. "insufficient samples" alone leaves the reader to guess how much more to
      # run; DIAG-11 in AGENTS.md is built on this string saying what to change.
      def percentile(sorted, name, fraction)
        required = required_samples(name)
        if sorted.length < required
          return Measurement.unavailable(
            "insufficient samples for #{name} (need #{required}, have #{sorted.length}); " \
            "raise requests_per_endpoint_per_level"
          )
        end

        Measurement.value(quantile(sorted, fraction))
      end

      # Linear interpolation between order statistics (the "type 7" definition used by
      # NumPy, R's default, and most APM tooling). Nearest-rank would be simpler and
      # would report the maximum as p99 for any sample under 100, which is precisely
      # the fabrication this class exists to avoid.
      def quantile(sorted, fraction)
        return nil if sorted.empty?
        return sorted.first if sorted.length == 1

        position = (sorted.length - 1) * fraction
        lower = position.floor
        upper = position.ceil
        return sorted[lower] if lower == upper

        sorted[lower] + ((sorted[upper] - sorted[lower]) * (position - lower))
      end

      def standard_deviation(sorted)
        return nil if sorted.length < MIN_SAMPLES_FOR_DISPERSION

        mean = sorted.sum / sorted.length
        # Sample standard deviation (n-1). The cell is a sample of the endpoint's
        # behaviour, not the whole population of requests it will ever serve.
        Math.sqrt(sorted.sum { |value| (value - mean)**2 } / (sorted.length - 1))
      end

      def coefficient_of_variation(sorted)
        if sorted.length < MIN_SAMPLES_FOR_DISPERSION
          return Measurement.unavailable(
            "dispersion needs at least #{MIN_SAMPLES_FOR_DISPERSION} samples; have #{sorted.length}"
          )
        end

        mean = sorted.sum / sorted.length
        return Measurement.unavailable("mean latency is zero; the coefficient of variation is undefined") if
          mean.zero?

        Measurement.value(standard_deviation(sorted) / mean)
      end

      def caveat_for(name, summary)
        parts = []
        highest = PERCENTILES.keys.last
        unless name == highest
          missing = PERCENTILES.keys.reject { |candidate| summary.supported?(candidate) }
          parts << "checked at #{name} because #{missing.join('/')} " \
                   "#{missing.length == 1 ? 'is' : 'are'} not supported by #{summary.sample_count} sample(s); " \
                   "a #{name} within budget does not prove #{missing.first} is"
        end
        parts << "high variance (CV #{summary.coefficient_of_variation.value.round(2)}); " \
                 "this figure is being pulled by outliers" if summary.high_variance?

        parts.empty? ? nil : parts.join(". ")
      end
    end
  end
end
