# frozen_string_literal: true

module Loadwright
  # Base class for everything Loadwright raises. Host apps can rescue this
  # single class to catch anything originating in the gem.
  class Error < StandardError; end

  # A foreign exception's message, bounded.
  #
  # Ruby builds a NoMethodError's message from the RECEIVER'S INSPECT, so one raised
  # against a large object -- an RSpec configuration, a Rails application -- carries
  # twelve thousand characters of internal state, and the four words that matter are
  # somewhere in the middle. Used where someone else's exception crosses into our
  # output or into a persisted record.
  MAX_FOREIGN_MESSAGE = 400

  def self.brief(error)
    message = error.respond_to?(:message) ? error.message.to_s : error.to_s
    return "#{error.class}: #{message}" if message.length <= MAX_FOREIGN_MESSAGE

    "#{error.class}: #{message[0, MAX_FOREIGN_MESSAGE]}… (#{message.length} characters, truncated)"
  end

  # Raised when a run is refused by the safety guard. See
  # references/production-safety.md. This is a *successful* outcome for the
  # guard, not a bug — it means the gem declined to generate load.
  class SafetyError < Error; end

  # Raised when configuration is internally inconsistent and the run cannot
  # start (e.g. :transactional_rollback cleanup selected in :http mode).
  class ConfigurationError < Error; end

  # Raised by Measurement#value when the measurement is unavailable. Deliberate:
  # the alternative is returning nil, which reads as zero somewhere downstream
  # and produces exactly the confidently-wrong number this gem exists to avoid.
  class UnavailableMeasurementError < Error; end

  # Raised when an enabled side-effect containment measure cannot be enforced
  # and abort_if_containment_unavailable is true. Believing you are contained
  # when you are not is the failure that mails real customers from a dev box, so
  # this is a subclass of SafetyError rather than a generic error.
  class ContainmentError < SafetyError; end

  # Raised when endpoint discovery cannot produce a COMPLETE endpoint list.
  # Partial discovery is never returned: an endpoint that was never tested would
  # be reported as absent rather than skipped, which tells a developer their API
  # is clean when half of it was never looked at.
  class DiscoveryError < Error; end

  # Raised when seeding cannot proceed for a reason the user must fix — most
  # commonly a factory missing a `sequence` for a uniquely-constrained field.
  # Never rescued into a silent workaround; see discovery-and-load-engine.md.
  class SeedingError < Error; end

  # Raised when the app under test cannot be booted or reached in :http mode.
  class ServerError < Error; end

  # Rung 5 of the contention ladder: the database is not recovering and
  # continuing would do harm rather than gather data. A partial report is still
  # written — an aborted run must produce output, never nothing.
  class RunAborted < Error
    attr_reader :rung

    def initialize(message, rung: nil)
      super(message)
      @rung = rung
    end
  end

  # Raised in the run loop after SIGINT/SIGTERM so the normal unwind path (and
  # therefore the normal teardown path) runs. The signal handler itself never
  # raises — see Lifecycle.
  class Interrupted < Error; end
end
