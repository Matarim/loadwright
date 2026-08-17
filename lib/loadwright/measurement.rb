# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  # A single measured quantity that may not have been measurable.
  #
  # Every numeric signal Loadwright collects is wrapped in one of these. The
  # type is deliberately tri-state — value / unavailable-with-reason — and
  # deliberately *not* nullable.
  #
  # The reasoning, from CLAUDE.md corollary 5: a confidently wrong "all clear"
  # is its own kind of harm. A nil query count formatted into a report renders
  # as "0" or "-", both of which a reader interprets as "measured, and fine".
  # An unavailable Measurement cannot be rendered that way, because it carries
  # the reason it is missing and refuses to produce a number.
  #
  #   Measurement.value(12)                      #=> available
  #   Measurement.unavailable("no collector")    #=> unavailable, with reason
  #
  # There is intentionally no #to_i, #to_f, #coerce, or #+ on this class.
  # Arithmetic on a possibly-unmeasured quantity has to be an explicit decision
  # at the call site, which is what #map and #value_or are for.
  class Measurement
    UNAVAILABLE = Object.new.freeze
    private_constant :UNAVAILABLE

    class << self
      # An actual measured value. nil is rejected: "measured, and it was nil"
      # is not a meaningful state, and allowing it reintroduces exactly the
      # ambiguity this class removes.
      def value(raw)
        raise ArgumentError, "Measurement.value(nil) is not meaningful; use .unavailable(reason)" if raw.nil?

        new(raw, nil)
      end

      # A quantity that could not be measured, and why. The reason is required
      # and is surfaced verbatim in reports — it is what tells a developer
      # whether to switch execution mode, install the middleware, or raise
      # requests_per_endpoint_per_level.
      def unavailable(reason)
        reason = reason.to_s
        raise ArgumentError, "an unavailable Measurement requires a reason" if reason.strip.empty?

        new(UNAVAILABLE, reason)
      end
    end

    attr_reader :reason

    def initialize(raw, reason)
      @raw = raw
      @reason = reason
      freeze
    end
    private_class_method :new

    def available?
      !@raw.equal?(UNAVAILABLE)
    end

    def unavailable?
      !available?
    end

    # Raises rather than returning nil. Call sites that can tolerate absence
    # should say so explicitly via #value_or or #map.
    def value
      raise UnavailableMeasurementError, "measurement unavailable: #{@reason}" if unavailable?

      @raw
    end

    def value_or(default)
      available? ? @raw : default
    end

    # Transforms an available value, propagating unavailability untouched, so a
    # reason survives a chain of derivations instead of being replaced by a
    # generic one at the end.
    def map
      return self if unavailable?

      self.class.value(yield(@raw))
    end

    def ==(other)
      other.is_a?(self.class) &&
        other.available? == available? &&
        other.reason == reason &&
        (unavailable? || other.value == @raw)
    end
    alias eql? ==

    def hash
      [self.class, available?, @reason, available? ? @raw : nil].hash
    end

    def to_s
      available? ? @raw.to_s : "unavailable (#{@reason})"
    end

    def inspect
      available? ? "#<Loadwright::Measurement #{@raw.inspect}>" : "#<Loadwright::Measurement unavailable: #{@reason}>"
    end
  end
end
