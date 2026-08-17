# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Discovery
    # Records real requests by wrapping ActionDispatch::Integration::Session#process
    # while the app's own specs run. Recording, never static parsing.
    #
    # The hard part is not interception: the recorder observes /api/v1/posts/42 but
    # the merge key is (path_template, verb), so each request must be reverse-mapped
    # through Rails.application.routes.recognize_path to recover the pattern. The
    # concrete ids are kept too — they are resolution source 2 for path params.
    #
    # Specified in references/discovery-and-load-engine.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class IntegrationSpecSource
      def record!(*, **, &)
        raise NotImplementedError, "Loadwright::Discovery::IntegrationSpecSource#record! is not implemented yet"
      end

      def endpoints(*, **, &)
        raise NotImplementedError, "Loadwright::Discovery::IntegrationSpecSource#endpoints is not implemented yet"
      end
    end
  end
end
