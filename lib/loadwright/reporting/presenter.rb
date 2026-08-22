# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Reporting
    # The one place a value becomes a string.
    #
    # ===========================================================================
    # WHY A SHARED LAYER RATHER THAN THREE RENDERERS. Every format has to make the
    # same handful of judgement calls, and each of them is a place the tool can lie:
    #
    #   * An unavailable Measurement must render its REASON. Not a dash, not a blank
    #     cell, and never a zero -- all three read as "measured, and fine", which is
    #     the exact confusion Measurement exists to prevent. If HTML gets this right
    #     and Markdown prints "—", the Markdown report is the dangerous one.
    #
    #   * `inconclusive` must never look like `healthy`. Three states, visually
    #     distinct, in every format.
    #
    #   * A cell that was stepped down must show the level it ACTUALLY ran at.
    #
    # Putting these in one module means a new format inherits the honesty rather
    # than having to re-derive it.
    # ===========================================================================
    #
    # NOTHING HERE READS config.execution_mode. The mode is a value carried in run
    # metadata and displayed; every decision about what is measurable comes from
    # the capability record. A spec enforces it.
    module Presenter
      module_function

      # A serialised Measurement is `{ value: x }` or `{ unavailable: "reason" }`.
      # Anything else is a bare value from an older record.
      def measurement(serialised, precision: nil)
        return unavailable_text("not recorded") if serialised.nil?

        hash = symbolize(serialised)
        return number(hash[:value], precision) if hash.is_a?(Hash) && hash.key?(:value)
        return unavailable_text(hash[:unavailable]) if hash.is_a?(Hash) && hash.key?(:unavailable)

        number(serialised, precision)
      end

      def measurement_available?(serialised)
        hash = symbolize(serialised)

        hash.is_a?(Hash) ? hash.key?(:value) : !serialised.nil?
      end

      def measurement_value(serialised)
        hash = symbolize(serialised)

        hash.is_a?(Hash) ? hash[:value] : serialised
      end

      # THE REASON IS THE ACTIONABLE PART, so it is rendered in full rather than
      # truncated to fit a column. A reason a reader cannot act on is no better than
      # a blank.
      def unavailable_text(reason)
        reason.to_s.strip.empty? ? "unavailable" : "unavailable — #{reason}"
      end

      def number(value, precision = nil)
        return "" if value.nil?
        return value.to_s unless value.is_a?(Numeric)

        precision ? format("%.#{precision}f", value) : value.to_s
      end

      # ------------------------------------------------------------------- states

      STATE_LABELS = {
        "healthy" => "healthy",
        "has_findings" => "has findings",
        "inconclusive" => "inconclusive"
      }.freeze

      def state_label(state) = STATE_LABELS.fetch(state.to_s, state.to_s)

      def state_class(state) = "state-#{state.to_s.tr('_', '-')}"

      # Ordering for the per-endpoint list: problems first, then the endpoints we
      # could not judge, then the clean ones. An inconclusive endpoint sits ABOVE a
      # healthy one deliberately -- it is unfinished business, not a pass.
      STATE_ORDER = { "has_findings" => 0, "inconclusive" => 1, "healthy" => 2 }.freeze

      def state_rank(state) = STATE_ORDER.fetch(state.to_s, 3)

      # --------------------------------------------------------------- percentiles

      # Percentiles the sample could not support are OMITTED, with what they would
      # have needed. Printing them with a caveat is not good enough: a reader who
      # skims sees a number.
      def percentiles(cell)
        serialised = (cell || {})[:percentiles] || {}

        serialised.map do |name, value|
          hash = symbolize(value)
          { name: name.to_s,
            available: measurement_available?(value),
            text: measurement(value, precision: 1),
            # The bare reason, for a caller that has already said "omitted" and would
            # otherwise print "Omitted: unavailable — ...".
            reason: hash.is_a?(Hash) ? hash[:unavailable] : nil }
        end
      end

      def sample_note(cell)
        count = (cell || {})[:sample_count]
        return "no samples" if count.nil?

        "#{count} sample#{count == 1 ? '' : 's'}"
      end

      # ----------------------------------------------------------------- capability

      # PER WINDOW, NEVER ONE GLOBAL CLAIM. Capability genuinely changes mid-run --
      # the collector middleware can stop answering, and under :http the app process
      # can die outright. A single "this run supports X" banner is a lie in any
      # degraded run, and the degraded run is the one where a wrong claim does the
      # most damage.
      def capability_epochs(capabilities)
        Array((capabilities || {})[:epochs]).map do |epoch|
          {
            index: epoch[:index],
            cause: epoch[:cause],
            started_at: epoch[:started_at],
            signals: Array(epoch[:capabilities]).map do |signal, capability|
              { name: signal.to_s, status: capability[:status].to_s, reason: capability[:reason] }
            end
          }
        end
      end

      def degraded?(capabilities) = (capabilities || {})[:degraded] == true

      def lost_signals(capabilities) = Array((capabilities || {})[:lost_signals]).map(&:to_s)

      # ---------------------------------------------------------------------- cells

      # A stepped-down cell must never display the level it was ASKED to run at. The
      # number a reader takes away has to be the number that happened.
      def concurrency_text(cell)
        requested = cell[:requested_concurrency]
        actual = cell[:actual_concurrency]
        return requested.to_s if actual.nil? || actual == requested

        "#{actual} (stepped down from #{requested})"
      end

      def cell_label(cell)
        parts = ["#{cell[:sweep]}"]
        parts << "scale #{cell[:scale_factor]}" if cell[:scale_factor]
        parts << "page #{cell[:page_size] || 'default'}"
        parts.join(", ")
      end

      # ------------------------------------------------------------------ breakdown

      # Percentage shares for the stacked time view. An endpoint that is 80%
      # serialisation must not read as a database problem, and a stacked bar is what
      # makes that legible at a glance where four numbers in a row do not.
      COMPONENTS = %i[db view gc other].freeze

      COMPONENT_LABELS = {
        db: "database", view: "view / serialisation", gc: "GC", other: "everything else"
      }.freeze

      def breakdown_shares(breakdown)
        return [] if breakdown.nil?

        total = breakdown[:total_ms].to_f
        return [] if total <= 0

        COMPONENTS.filter_map do |component|
          value = breakdown[:"#{component}_ms"]
          next if value.nil?

          { component: component, label: COMPONENT_LABELS.fetch(component),
            ms: value.to_f, share: (value.to_f / total) * 100.0 }
        end
      end

      # ------------------------------------------------------------------- helpers

      def symbolize(value)
        return value unless value.is_a?(Hash)

        value.to_h { |key, nested| [key.respond_to?(:to_sym) ? key.to_sym : key, nested] }
      end

      def duration(seconds)
        return "unknown" if seconds.nil?
        return "#{seconds.round(1)}s" if seconds < 60

        "#{(seconds / 60.0).round(1)} minutes"
      end

      def pluralise(count, singular, plural = nil)
        "#{count} #{count == 1 ? singular : plural || "#{singular}s"}"
      end
    end
  end
end
