# frozen_string_literal: true

require "loadwright/capability_profile"
require "loadwright/errors"

module Loadwright
  # Run-scoped record of what Loadwright could measure, and when that changed.
  #
  # This is the mutable half of the capability design, deliberately separated
  # from CapabilityProfile so the profile itself stays a frozen value object.
  #
  # Capability is not constant across a run. The collector middleware can stop
  # responding; under :http the app process can die outright
  # (resource-contention.md Part 7 requires handling exactly that). A profile
  # computed once and frozen for the whole run would attribute full-capability
  # findings to a window in which collection had already silently failed —
  # which is the confidently-wrong-number failure this whole design exists to
  # prevent, just relocated.
  #
  # So: the timeline holds an ordered list of epochs. Every result records the
  # epoch it was collected under, and reporting renders capability per window
  # rather than making one claim for the entire run.
  class CapabilityTimeline
    Epoch = Struct.new(:index, :profile, :cause, :started_at, keyword_init: true) do
      def initial? = index.zero?
    end

    attr_reader :epochs

    def initialize(initial_profile, clock: -> { Time.now })
      raise ArgumentError, "expected a CapabilityProfile" unless initial_profile.is_a?(CapabilityProfile)

      @clock = clock
      @epochs = [Epoch.new(index: 0, profile: initial_profile, cause: nil, started_at: @clock.call)]
    end

    def current       = @epochs.last.profile
    def current_epoch = @epochs.last.index

    def profile_at(epoch_index)
      found = @epochs.find { |e| e.index == epoch_index }
      raise ArgumentError, "no such capability epoch: #{epoch_index.inspect}" unless found

      found.profile
    end

    # Downgrades one or more signals from this point forward and opens a new
    # epoch. Returns the new epoch index, which callers attach to subsequent
    # results.
    #
    # Idempotent: degrading signals that are already at or below the requested
    # status does not open a redundant epoch, so a middleware that fails on
    # every request does not produce one epoch per request.
    def degrade!(*signals, reason:, status: :unavailable)
      signals = signals.flatten
      raise ArgumentError, "degrade! requires at least one signal" if signals.empty?

      degraded = current.degrade(signals, reason: reason, status: status)
      return current_epoch if degraded == current

      @epochs << Epoch.new(
        index: @epochs.length,
        profile: degraded,
        cause: reason.to_s,
        started_at: @clock.call
      )
      current_epoch
    end

    def degraded? = @epochs.length > 1

    # The signals that were available at the start of the run but are not now.
    # This is what a report's "this run degraded partway" banner is built from.
    def lost_signals
      initial = @epochs.first.profile
      CapabilityProfile::SIGNALS.select { |s| initial.available?(s) && !current.available?(s) }
    end

    def to_h
      {
        degraded: degraded?,
        lost_signals: lost_signals,
        epochs: @epochs.map do |e|
          { index: e.index, cause: e.cause, started_at: e.started_at, capabilities: e.profile.to_h }
        end
      }
    end
  end
end
