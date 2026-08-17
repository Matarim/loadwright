# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Reporting
    # The primary deliverable. Self-contained: inline CSS/JS, no CDN, opens offline.
    #
    # Specified in references/reporting.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class HtmlReport
      def render(*, **, &)
        raise NotImplementedError, "Loadwright::Reporting::HtmlReport#render is not implemented yet"
      end
    end
  end
end
