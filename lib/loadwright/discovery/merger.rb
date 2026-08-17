# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Discovery
    # Merges sources by (path_template, verb): integration-spec examples win on
    # fidelity, OpenAPI schemas are kept for response validation.
    #
    # Specified in references/discovery-and-load-engine.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class Merger
      def merge(*, **, &)
        raise NotImplementedError, "Loadwright::Discovery::Merger#merge is not implemented yet"
      end
    end
  end
end
