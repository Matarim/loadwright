# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  # Which classes of finding this run was actually able to look for.
  #
  # WHY THIS EXISTS. An endpoint's outcome state has to be derived from
  # finding-class COVERAGE, not from how many signals happened to produce a
  # number. The alternative we started with — emitting a zero-confidence
  # "finding" when a signal was unmeasurable — is a category error twice over:
  # it inflates the finding count, and the word "finding" says something is
  # wrong with the APP when what is actually true is that something is missing
  # from our COVERAGE. Unavailability belongs in Measurement, which is what
  # Measurement is for.
  #
  # A finding class is covered when AT LEAST ONE of its detectors was
  # measurable. Two detectors for one class is redundancy, not a requirement:
  # if the pattern-match detector ran and came back clean, the N+1 class was
  # covered, and the slope being unmeasurable does not change what we can say.
  # If BOTH N+1 detectors were unavailable, an N+1 genuinely cannot be ruled
  # out and the endpoint is inconclusive.
  #
  # THREE DETECTOR STATES, NOT TWO, and the third is what stops this flooding
  # every report with `inconclusive`:
  #
  #   :available      ran, produced a usable answer -> covers its class
  #   :unavailable    was attempted and could not answer (no query data, result
  #                   size could not be varied) -> a real coverage gap
  #   :not_applicable was never attempted at all, because the subsystem is not
  #                   in this build or the user disabled it -> reported, but NOT
  #                   a gap this run can be blamed for
  #
  # Collapsing :not_applicable into :unavailable would make every endpoint
  # inconclusive for index analysis until ExplainAnalyzer ships, which would
  # make the state meaningless — precisely the failure the three-state outcome
  # model exists to avoid, relocated one level down.
  class Coverage
    # Finding class -> the detectors that can cover it. The N+1 class is the only
    # one with redundancy today, and it is the one that needs it: the
    # pattern-match and slope detectors fail in different circumstances.
    CLASSES = {
      n_plus_one: %i[pattern_match slope],
      missing_pagination: %i[payload_growth],
      over_fetch: %i[query_response_comparison],
      index_scan: %i[explain],
      latency: %i[percentiles]
    }.freeze

    DETECTORS = CLASSES.values.flatten.freeze

    # Classes whose gap is REPORTED but never escalates to :inconclusive.
    #
    # Over-fetch is the one, and it follows from what over-fetch is: a low-confidence
    # HINT that must never fail a build, because data is legitimately loaded for
    # authorisation and filtering without being serialised. `inconclusive` is a much
    # stronger statement than a hint — it says the endpoint could not be judged. Letting
    # the weakest signal in the system veto the clean verdict of every strong one gets
    # the ordering exactly backwards, and would flood reports with `inconclusive` for a
    # signal that was never allowed to matter.
    #
    # The gap still appears in #describe, so a reader sees it was not checked.
    #
    # ADMISSION RULE, because this list is a hazard as well as a mechanism. The
    # foreseeable misuse is someone adding a noisy class here to quiet a report,
    # laundering a real signal through a mechanism built for an unfalsifiable one.
    # The bar (response-analysis.md, "Admission rule"):
    #
    #   A class may be advisory ONLY if its findings are inherently unfalsifiable
    #   from Loadwright's vantage point — the same observation is produced by
    #   correct and incorrect code, and nothing we can see distinguishes them.
    #
    # Over-fetch qualifies: a queried table whose data never reaches the response
    # is produced just as readily by an authorization check, a filter, or a
    # callback as by a wasteful eager load, and from outside the app there is no
    # way to tell. Better detection cannot fix that — only information we do not
    # have.
    #
    # "Noisy" and "low confidence" are NOT grounds. Those are detection problems,
    # and the fix is better detection or a narrower condition, not exemption from
    # the state model. Adding a class here is a documentation change first.
    ADVISORY_CLASSES = %i[over_fetch].freeze

    STATES = %i[available unavailable not_applicable].freeze

    LABELS = {
      n_plus_one: "N+1",
      missing_pagination: "pagination",
      over_fetch: "over-fetch",
      index_scan: "index analysis",
      latency: "latency percentiles"
    }.freeze

    DETECTOR_LABELS = {
      pattern_match: "pattern",
      slope: "slope",
      payload_growth: "payload growth",
      query_response_comparison: "query/response comparison",
      explain: "EXPLAIN",
      percentiles: "percentiles"
    }.freeze

    Detector = Struct.new(:name, :state, :reason, keyword_init: true) do
      def available? = state == :available
      def unavailable? = state == :unavailable
      def not_applicable? = state == :not_applicable

      def to_h = { detector: name, state: state, reason: reason }.compact
    end

    attr_reader :detectors

    # `detectors` maps a detector name to :available, or to a [state, reason]
    # pair. Anything not mentioned is :not_applicable — a detector that was never
    # wired up cannot honestly be reported as a gap in this run's coverage.
    def initialize(detectors = {})
      unknown = detectors.keys - DETECTORS
      raise ArgumentError, "unknown detector(s): #{unknown.join(', ')}" if unknown.any?

      @detectors = DETECTORS.to_h { |name| [name, build(name, detectors[name])] }.freeze
      freeze
    end

    def self.none = new

    def [](name)
      @detectors.fetch(name) { raise ArgumentError, "unknown detector #{name.inspect}" }
    end

    def detectors_for(finding_class)
      CLASSES.fetch(finding_class) { raise ArgumentError, "unknown finding class #{finding_class.inspect}" }
             .map { |name| self[name] }
    end

    # Covered when at least one detector answered.
    def covered?(finding_class) = detectors_for(finding_class).any?(&:available?)

    # A real gap: something was attempted for this class and nothing answered.
    #
    # Advisory classes are excluded — they report their gap without escalating, for
    # the reason given at ADVISORY_CLASSES.
    def uncovered?(finding_class)
      return false if ADVISORY_CLASSES.include?(finding_class)

      detectors = detectors_for(finding_class)

      detectors.none?(&:available?) && detectors.any?(&:unavailable?)
    end

    # Attempted and unanswered, regardless of whether it escalates. What #describe
    # reports, and what an advisory gap shows up as.
    def unanswered?(finding_class)
      detectors = detectors_for(finding_class)

      detectors.none?(&:available?) && detectors.any?(&:unavailable?)
    end

    # Never attempted. Visible in the report, but not a gap this run caused.
    def not_applicable?(finding_class) = detectors_for(finding_class).all?(&:not_applicable?)

    def covered_classes    = CLASSES.keys.select { |name| covered?(name) }
    def uncovered_classes  = CLASSES.keys.select { |name| uncovered?(name) }
    def not_applicable_classes = CLASSES.keys.select { |name| not_applicable?(name) }

    def complete? = uncovered_classes.empty?

    # Why a class has no coverage, for the report and for the inconclusive detail.
    def reasons_for(finding_class)
      detectors_for(finding_class).reject(&:available?).filter_map(&:reason).uniq
    end

    def uncovered_detail
      uncovered_classes.map do |finding_class|
        reasons = reasons_for(finding_class)
        "#{LABELS.fetch(finding_class)}#{reasons.empty? ? '' : " (#{reasons.join('; ')})"}"
      end.join(", ")
    end

    # REPORTED ON EVERY ENDPOINT, whatever the state. This is what makes the
    # coverage rule honest rather than merely tidy: a reader can see that an
    # otherwise-clean endpoint was checked with one N+1 detector instead of two,
    # without us having to overload `inconclusive` to signal it.
    #
    #   "checked: N+1 (pattern), pagination, over-fetch — not checked: index
    #    analysis (EXPLAIN not implemented in this version)"
    def describe
      checked = covered_classes.map do |finding_class|
        available = detectors_for(finding_class).select(&:available?).map { |d| DETECTOR_LABELS.fetch(d.name) }
        partial = available.length < CLASSES.fetch(finding_class).length

        partial ? "#{LABELS.fetch(finding_class)} (#{available.join(', ')})" : LABELS.fetch(finding_class)
      end

      skipped = CLASSES.keys.select { |c| unanswered?(c) || not_applicable?(c) }.map do |finding_class|
        reasons = reasons_for(finding_class)
        "#{LABELS.fetch(finding_class)}#{reasons.empty? ? '' : " (#{reasons.first})"}"
      end

      [
        checked.empty? ? nil : "checked: #{checked.join(', ')}",
        skipped.empty? ? nil : "not checked: #{skipped.join(', ')}"
      ].compact.join(" — ")
    end

    def to_h
      {
        complete: complete?,
        covered: covered_classes,
        uncovered: uncovered_classes,
        unanswered: CLASSES.keys.select { |c| unanswered?(c) },
        not_applicable: not_applicable_classes,
        description: describe,
        detectors: @detectors.values.map(&:to_h)
      }
    end

    def ==(other) = other.is_a?(self.class) && other.detectors == detectors
    alias eql? ==

    def hash = [self.class, @detectors].hash

    private

    def build(name, value)
      case value
      when nil then Detector.new(name: name, state: :not_applicable, reason: nil)
      when :available then Detector.new(name: name, state: :available, reason: nil)
      when Array then validated(name, value[0], value[1])
      when Symbol then validated(name, value, nil)
      else raise ArgumentError, "unusable detector value for #{name}: #{value.inspect}"
      end
    end

    def validated(name, state, reason)
      raise ArgumentError, "unknown detector state #{state.inspect}" unless STATES.include?(state)
      if state == :unavailable && reason.to_s.strip.empty?
        raise ArgumentError, "an unavailable detector (#{name}) requires a reason"
      end

      Detector.new(name: name, state: state, reason: reason)
    end
  end
end
