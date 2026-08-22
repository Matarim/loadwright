# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Analysis
    # What containment did to the numbers, said out loud.
    #
    # ===========================================================================
    # THIS IS REQUIRED, NOT OPTIONAL (performance-signals.md Part 1).
    #
    # `suppress_background_jobs` and `block_outbound_http` make the app FASTER than
    # production reality: jobs are recorded instead of performed, third-party calls
    # return instantly or not at all. That is the correct default -- a load test must
    # not mail 500 real customers from a laptop -- but a latency figure produced under
    # it is not the latency a user would see, and printing it unqualified is the same
    # category of error as reporting a 403 as fast.
    #
    # The time does not merely shrink, it DISAPPEARS from the breakdown: a blocked
    # outbound call contributes nothing to db, view, GC, or other, so the components
    # still sum to the total and the total is simply lower. Nothing in the numbers
    # hints at what is missing, which is exactly why it has to be stated in words.
    # ===========================================================================
    #
    # The disclosure is attached to run metadata AND to each endpoint's time breakdown,
    # because those get read separately -- someone skimming one endpoint's section must
    # not have to know what the header said.
    class ContainmentDisclosure
      # Per measure: what it does to the numbers when it IS enforced, and what it does
      # to them when the user turned it off. Both directions matter. A run without
      # containment produces findings that may reflect a third party's latency rather
      # than the app's, which is its own kind of misattribution.
      EFFECTS = {
        outbound_http: {
          enforced: "outbound HTTP was blocked, so any time the app would have spent calling a third " \
                    "party is absent from these figures entirely -- real-world latency will be higher. " \
                    "The missing time appears in no component, not even `other`.",
          disabled: "outbound HTTP was NOT blocked, so these figures include real third-party latency. " \
                    "A slow endpoint here may be reporting someone else's outage."
        },
        background_jobs: {
          enforced: "background jobs were recorded rather than performed, so the work they represent is " \
                    "not in these figures. Jobs enqueued per request is reported separately and is the " \
                    "signal to read instead.",
          disabled: "background jobs were NOT suppressed, so inline adapters performed real work during " \
                    "the run and that work is inside these figures."
        },
        mail: {
          enforced: "mail was captured rather than delivered, so SMTP time is absent from these figures.",
          disabled: "mail was NOT suppressed; delivery time is inside these figures, and real mail may " \
                    "have been sent."
        }
      }.freeze

      # Only these actually move latency. Mail suppression matters for safety far more
      # than for timing, so it is recorded but does not by itself flag the numbers as
      # skewed -- crying skew on every default run would make the flag meaningless.
      TIMING_RELEVANT = %i[outbound_http background_jobs].freeze

      Note = Struct.new(:measure, :enforced, :text, keyword_init: true) do
        def to_h = { measure: measure, enforced: enforced, note: text }
      end

      def self.from(containment)
        return none if containment.nil?

        new(Array(containment.measures).map { |measure| [measure.name.to_sym, measure.enforced] }.to_h)
      end

      def self.none = new({})

      attr_reader :states

      def initialize(states)
        @states = states.freeze
        freeze
      end

      # True when at least one timing-relevant measure was in force. The report leads
      # with this: it is the difference between "340ms" and "340ms, with the network
      # calls removed".
      def skewed?
        TIMING_RELEVANT.any? { |measure| @states[measure] }
      end

      def notes
        @states.filter_map do |measure, enforced|
          effect = EFFECTS[measure]
          next if effect.nil?

          Note.new(measure: measure, enforced: enforced, text: effect[enforced ? :enforced : :disabled])
        end
      end

      # One line for a report header or a terminal summary. Deliberately leads with the
      # DIRECTION of the error, because that is what a reader needs before the number.
      # nil when there is no containment record at all -- a dry run, or a caller that
      # never installed it. Silence is right there: "no containment was active" is a
      # claim about the run, and we do not have one to make it about.
      def summary
        return nil if notes.empty?

        prefix = skewed? ? "These latency figures are lower than production reality: " : ""
        "#{prefix}#{notes.map(&:text).join(' ')}"
      end

      # One clause, for places that need the warning without the full explanation --
      # under every endpoint's time breakdown, say, where the long form would push the
      # numbers off the screen and train the reader to skip it.
      def headline
        return nil if notes.empty?
        return "Contained run: these figures are lower than production reality." if skewed?

        "Uncontained run: these figures include real side-effect latency."
      end

      def to_h
        {
          skewed: skewed?,
          headline: headline,
          summary: summary,
          notes: notes.map(&:to_h)
        }.compact
      end
    end
  end
end
