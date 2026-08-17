# frozen_string_literal: true

require "loadwright/measurement"

module Loadwright
  module Execution
    # What every collector returns for one request. The other half of RawResponse.
    #
    # EVERY NUMERIC FIELD IS A Measurement, never a bare Integer and never nil.
    # This is the single most important property of this class. A collector that
    # cannot see the app's instrumentation — External, against a remote target
    # that does not load the gem — returns `unavailable("no collector
    # middleware...")` for query_count, and there is no code path that turns that
    # into 0. A zero query count is the single most dangerous wrong number this
    # tool could print: it reads as a perfectly optimised endpoint.
    #
    # Construct via .unavailable(reason) for the degraded case rather than by
    # passing nils, so a new field added later is unavailable by default instead
    # of silently nil.
    class RequestMetrics
      # Query structure. `queries` holds normalised fingerprints with call sites;
      # `query_count` is its size when available, but is kept separate because
      # the Middleware collector can get a count from a response header while the
      # detail retrieval fails.
      MEASURED_FIELDS = %i[
        query_count
        distinct_query_count
        db_runtime_ms
        view_runtime_ms
        allocations
        gc_count
        gc_time_ms
        pool_size
        pool_busy
        pool_waiting
        mail_deliveries
        jobs_enqueued
        unattributed_query_count
      ].freeze

      attr_reader :request_id, :capability_epoch, :queries, :collector

      MEASURED_FIELDS.each { |field| attr_reader field }

      def initialize(request_id:, collector: nil, capability_epoch: 0, queries: [], **measured)
        unknown = measured.keys - MEASURED_FIELDS
        raise ArgumentError, "unknown metric(s): #{unknown.join(', ')}" if unknown.any?

        @request_id = request_id
        @collector = collector
        @capability_epoch = capability_epoch
        @queries = queries.freeze

        MEASURED_FIELDS.each do |field|
          value = measured.fetch(field) do
            Measurement.unavailable("#{field} was not collected by the #{collector || 'unknown'} collector")
          end
          raise ArgumentError, "#{field} must be a Measurement, got #{value.class}" unless value.is_a?(Measurement)

          instance_variable_set(:"@#{field}", value)
        end

        freeze
      end

      # Every field unavailable for the same reason. The External collector's
      # whole query-derived half, and the shape a mid-run collection failure
      # produces.
      def self.unavailable(request_id:, reason:, collector: nil, capability_epoch: 0, except: {})
        measured = MEASURED_FIELDS.to_h { |field| [field, Measurement.unavailable(reason)] }
        new(request_id: request_id, collector: collector, capability_epoch: capability_epoch,
            **measured.merge(except))
      end

      def [](field)
        raise ArgumentError, "unknown metric #{field.inspect}" unless MEASURED_FIELDS.include?(field)

        public_send(field)
      end

      def available?(field) = self[field].available?

      def any_query_data? = query_count.available?

      # Fingerprints seen more than once in a single request. The
      # pattern-matching half of N+1 detection; the slope half lives in
      # Analysis::ResponseCorrelator.
      def duplicate_fingerprints
        queries.group_by { |q| q[:fingerprint] }.select { |_, group| group.length > 1 }
      end

      # Note that an unavailable field serialises as
      # `{ unavailable: "<reason>" }`, NOT as nil. A nil in a persisted run record
      # or a report template renders as "0" or "—", both of which a reader takes
      # to mean "measured, and fine" — which is the exact confusion Measurement
      # exists to prevent, and it would be reintroduced here at the one point
      # where the type information is lost.
      def to_h
        fields = MEASURED_FIELDS.to_h do |field|
          measurement = self[field]
          [field, measurement.available? ? { value: measurement.value } : { unavailable: measurement.reason }]
        end

        fields.merge(
          request_id: request_id,
          collector: collector,
          capability_epoch: capability_epoch,
          # WITHOUT :sql. The raw statement is captured for EXPLAIN only (see
          # QueryTracker), and to_h is the boundary every persisted artefact crosses:
          # a run record, a JSON report, a bug-report attachment. The fingerprint is
          # what findings are built from, and it carries no bind values.
          query_sample: queries.first(50).map { |query| query.except(:sql) }
        )
      end
    end
  end
end
