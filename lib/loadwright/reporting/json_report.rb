# frozen_string_literal: true

require "json"
require "loadwright/errors"
require "loadwright/history/redactor"

module Loadwright
  module Reporting
    # Raw structured data, for anyone who wants to build their own tooling on top or
    # diff two runs programmatically.
    #
    # THE THIN ONE, AND DELIBERATELY SO. It emits the same structure the HTML and
    # Markdown reports render from, with no reshaping — the moment this format starts
    # "improving" the shape, the three formats stop being views over one thing and the
    # JSON stops being a faithful record of what the run produced.
    #
    # TWO PROPERTIES IT MUST NOT LOSE:
    #
    #   * An unavailable measurement serialises as `{"unavailable": "<reason>"}`,
    #     never as `null`. A null in a JSON document is read as zero or missing by
    #     whatever consumes it next, which reintroduces the confidently-wrong number
    #     at the one point where the type information would otherwise be lost.
    #
    #   * It is REDACTED, on the same path as the persisted run record. This file is
    #     the most likely of the three to be attached to a ticket or piped into
    #     another tool, and it is the one nobody reads before sharing.
    class JsonReport
      FORMAT = :json

      def initialize(config: Loadwright.configuration, redactor: nil)
        @config = config
        @redactor = redactor || History::Redactor.new(config: config)
      end

      def render(result)
        JSON.pretty_generate(document(result))
      end

      def document(result)
        @redactor.document(
          result.to_h.merge(
            schema: {
              # Consumers need to know how to read an unavailable value without
              # inferring it from an example that happens to be present.
              measurement: "an available measurement is {\"value\": x}; an unavailable one is " \
                           "{\"unavailable\": \"<reason>\"}. Never null, never 0.",
              states: %w[healthy has_findings inconclusive],
              inconclusive: "not measurable, and NOT a pass. Absence of findings on an inconclusive " \
                            "endpoint means nothing was checked.",
              format_version: 1
            }
          )
        )
      end

      def write!(result, path:)
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, render(result))
        path
      end
    end
  end
end
