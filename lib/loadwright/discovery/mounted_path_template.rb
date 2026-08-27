# frozen_string_literal: true

module Loadwright
  module Discovery
    # Infers a path template for endpoints behind a mounted Rack app.
    #
    # Rails sees `mount MountedApi => "/internal/api"` as ONE route, so route
    # recognition answers "/internal/api" for every request inside it. Three distinct
    # Grape endpoints recorded as one, requested at the bare mount point, and 404.
    #
    # The concrete paths are recorded, so the templates can be recovered from them: a
    # segment that LOOKS like an id becomes a parameter, everything else stays literal.
    #
    # ID-SHAPE ONLY, deliberately -- NOT "segments that vary between recordings". Two
    # sibling endpoints differ in exactly that way: `.../widgets/{id}/customer` and
    # `.../widgets/{id}/invoices` vary in their last segment, and
    # a variance rule merges them into one endpoint that is neither. Merging two real
    # endpoints is silent and wrong; leaving a slug concrete is visible, reported, and
    # fixable with path_param_overrides.
    #
    # Affects Grape, Sinatra, Roda, and any other `mount`ed Rack app.
    module MountedPathTemplate
      # Deliberately conservative. A false positive turns a real path segment into a
      # parameter and merges endpoints that should be separate; a false negative
      # leaves one endpoint per id, which is visible and reported.
      ID_LIKE = [
        /\A\d+\z/,                                          # 42
        /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, # uuid
        /\A[a-z]{2,8}[-_][0-9a-f-]{8,}\z/i,                 # wgt-cceacf3d-..., cus_1a2b3c
        /\A[0-9a-f]{16,}\z/i,                               # long hex
        /\A[0-9A-HJKMNP-TV-Z]{26}\z/                        # ulid
      ].freeze

      module_function

      # `records` are recorded-request hashes. Returns a new array with `template`
      # filled in for anything that collapsed to a mount point.
      def apply(records)
        collapsed, intact = records.partition { |record| collapsed?(record) }
        return records if collapsed.empty?

        assign_templates(collapsed)

        intact + collapsed
      end

      # The router matched, but only the mount point: the template is a strict prefix
      # of the path it was recognised from, so everything that identifies the endpoint
      # was thrown away.
      def collapsed?(record)
        template = record["template"].to_s
        path = record["path"].to_s
        return false if template.empty? || path.empty? || template == path
        return false if template.include?("{")

        path.split("?").first.to_s.start_with?("#{template.chomp('/')}/")
      end

      def assign_templates(group)
        group.each do |record|
          own = segments(record["path"])
          template = own.each_with_index.map do |segment, index|
            id_like?(segment) ? "{#{param_name(own, index)}}" : segment
          end

          record["template"] = "/#{template.join('/')}"
          record["path_values"] = extract_values(own, template)
          record["inferred_template"] = true
        end
      end

      def id_like?(segment) = ID_LIKE.any? { |pattern| segment.match?(pattern) }

      # Named for the segment before it where there is one -- `/widgets/{widget_id}`
      # reads far better than `/widgets/{p2}` -- falling back to position.
      def param_name(segments, index)
        previous = index.positive? ? segments[index - 1] : nil
        return "p#{index + 1}" if previous.nil? || id_like?(previous)

        "#{singular(previous)}_id"
      end

      def singular(word)
        return word.sub(/ies\z/, "y") if word.end_with?("ies")
        return word.chomp("s") if word.end_with?("s") && !word.end_with?("ss")

        word
      end

      def extract_values(segments, template)
        template.each_with_index.filter_map do |part, index|
          [part.delete("{}"), segments[index]] if part.start_with?("{")
        end.to_h
      end

      # Query string stripped, and empty segments dropped so a `//` from joining a
      # mount prefix to an inner path does not survive into the template. A trailing
      # `?view=detailed` otherwise made the last segment unrecognisable as an id, so
      # the whole path stayed literal and became one endpoint per record.
      def segments(path) = path.to_s.split("?").first.to_s.split("/").reject(&:empty?)
    end
  end
end
