# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Reporting
    # For pasting into a PR or Slack.
    #
    # Specified in references/reporting.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class MarkdownReport
      def render(*, **, &)
        raise NotImplementedError, "Loadwright::Reporting::MarkdownReport#render is not implemented yet"
      end
    end
  end
end
