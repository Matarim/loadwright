# frozen_string_literal: true

require "cgi"
require "loadwright/errors"
require "loadwright/reporting/presenter"

module Loadwright
  module Reporting
    # "Did my change make it worse?" rendered for a human.
    #
    # SECTION ORDER IS THE DESIGN. A comparison report is read in about four seconds
    # before someone decides whether to merge, so the ordering decides what they
    # actually learn:
    #
    #   1. REFUSAL, if the runs are not comparable. Nothing else is rendered — a
    #      plausible-looking meaningless delta is worse than no comparison, and
    #      showing one below a refusal notice invites reading it anyway.
    #   2. NEW FINDINGS. The headline. What this change broke.
    #   3. REGRESSIONS in measured values.
    #   4. STATE CHANGES, before "resolved" — because an endpoint that became
    #      unmeasurable will otherwise be read as a fix two sections later.
    #   5. RESOLVED. How a developer confirms a fix worked.
    #   6. WITHIN NOISE, last and clearly separated. Shown because the developer may
    #      want it, never presented as a regression.
    #
    # Resolved findings are NOT netted against new ones anywhere in this file. A fix
    # and a regression in one run are two facts, not zero.
    class ComparisonReport
      include Presenter

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      # Markdown by default: this is the artefact that goes into a PR description.
      def render(comparison, before: nil, after: nil)
        @comparison = comparison

        return refusal_markdown(before, after) unless comparison.comparable?

        [
          heading(before, after),
          verdict_line,
          # ALWAYS, not only when there are within-noise rows to hang it on. The bar a
          # latency delta had to clear is what makes every latency verdict in this
          # document readable, including on a comparison that has none.
          "_#{noise_floor_sentence}_",
          warnings_block,
          section("New findings", new_finding_rows, empty: "None. Nothing broke that was not already broken."),
          section("Regressions", regression_rows, empty: "None.", note: @comparison.machine_noise_note),
          # DIRECTLY AFTER REGRESSIONS, and before anything that reads as good news.
          # These are the rows most likely to be misread as wins: a query count that
          # fell because the endpoint returned fewer records. A reader who reaches
          # "Resolved" or a bare "No regressions." without passing these concludes
          # their fix worked.
          section("Changed, but not like-for-like", unattributable_rows, empty: nil,
                  note: "The basis for comparing these moved between the two runs, so none of " \
                        "them is reported as a regression or an improvement. The numbers are real; " \
                        "the comparison is not."),
          section("State changes", transition_rows, empty: nil),
          section("Resolved", resolved_rows, empty: nil),
          section("Within noise", noise_rows, empty: nil,
                  note: "Shown because you may want to see them. None of these cleared both the " \
                        "configured threshold and this machine's measured noise floor, so none is " \
                        "reported as a regression."),
          endpoint_set_block
        ].compact.reject(&:empty?).join("\n\n")
      end

      def render_html(comparison, before: nil, after: nil)
        body = render(comparison, before: before, after: after)

        <<~HTML
          <!doctype html>
          <html lang="en"><head><meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Loadwright comparison</title>
          <style>#{stylesheet}</style></head>
          <body><main><pre class="markdown">#{CGI.escapeHTML(body)}</pre></main></body></html>
        HTML
      end

      def write!(comparison, path:, before: nil, after: nil)
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(path))
        content = path.end_with?(".html") ? render_html(comparison, before: before, after: after)
                                          : render(comparison, before: before, after: after)
        File.write(path, content)
        path
      end

      private

      def heading(before, after)
        ids = [before&.run_id, after&.run_id].compact
        ids.empty? ? "# Loadwright comparison" : "# Loadwright comparison\n\n`#{ids.join('` → `')}`"
      end

      # A REFUSAL RENDERS NOTHING ELSE. Putting the deltas underneath a notice saying
      # they are meaningless is an invitation to read them anyway, and the reader who
      # skims is exactly the reader the gate exists to protect.
      def refusal_markdown(before, after)
        rows = @comparison.divergences.map { |d| [d.dimension, d.before.inspect, d.after.inspect] }

        [
          heading(before, after),
          "",
          "## Not comparable",
          "",
          "These runs differ on a dimension that changes what was measured, so no delta is " \
          "computed. A comparison across these conditions would look meaningful and would not be.",
          "",
          table(%w[Dimension Earlier Later], rows),
          "",
          remedy
        ].join("\n")
      end

      # A VERSION DIVERGENCE NEEDS A DIFFERENT SENTENCE. "Re-run under matching
      # configuration" is unhelpful when the dimension that moved is the tool: there is
      # no configuration to match, and the fix is to re-measure the baseline with the
      # version now installed.
      #
      # Worth saying plainly what it protects against, because the reading it prevents
      # is a pleasant one and people believe pleasant readings: a finding can disappear
      # between releases because a detector was corrected, and comparing across that
      # reports a fix nobody made.
      def remedy
        if @comparison.divergences.any? { |d| d.dimension.to_s == "loadwright_version" }
          return "These runs were measured by different versions of Loadwright, so a finding present " \
                 "in one and absent from the other may reflect a change to the detector rather than a " \
                 "change to your application. Re-run the earlier side with the version you have now, " \
                 "and compare the two fresh runs."
        end

        "Re-run one side under matching configuration, then compare again."
      end

      # THE WORD STAYS, THE QUALIFIER JOINS IT. Downgrading the verdict on a heuristic
      # would be the same error as the one being corrected, one direction over: a
      # comparison that quietly decided a regression was noise is worse than one that
      # made a reader think for a second. What was missing is not a softer word, it is
      # the sentence saying what the shape of the evidence looks like.
      def verdict_line
        return "No regressions." unless @comparison.regressed?
        return "**REGRESSED** — latency only, and it looks like the machine. See below." if
          @comparison.machine_noise_signature?

        "**REGRESSED** — see below."
      end

      # THE BAR, AS A NUMBER, AND WHERE IT CAME FROM.
      #
      # The prose said "this machine's measured noise floor" and printed no value
      # anywhere -- not in the document, not on either stream -- so a reader could not
      # tell what bar was applied, whether it was measured from history or read from a
      # stored baseline, or whether the measuring path had run at all. They were left
      # inferring it from which deltas survived, which is the guessing this section
      # exists to end.
      NOISE_FLOOR_SOURCES = {
        "baseline" => "read from the designated baseline",
        "measured" => "measured from another run on this commit",
        "unmeasured" => "no noise floor could be measured, so the bar is regression_threshold_pct alone " \
                        "-- a guess about this machine. Run the suite again on this commit and " \
                        "`baseline set` to measure one"
      }.freeze

      def noise_floor_sentence
        floor = @comparison.noise_floor
        source = NOISE_FLOOR_SOURCES.fetch(@comparison.noise_floor_source.to_s, nil)

        return "Noise floor: #{source || NOISE_FLOOR_SOURCES.fetch('unmeasured')}." if floor.nil?

        "Noise floor: #{(floor.to_f * 100).round(1)}%#{source ? " (#{source})" : ''}, " \
          "against a configured threshold of #{@config.regression_threshold_pct}%. " \
          "The higher of the two is the bar."
      end

      def warnings_block
        lines = @comparison.warnings.map { |warning| "- #{warning}" }
        lines += @comparison.excluded_signals.map { |signal| "- #{signal[:detail]}" }
        return "" if lines.empty?

        (["## Caveats", ""] + lines).join("\n")
      end

      def new_finding_rows
        @comparison.new_findings.map { |finding| [finding[:endpoint], "`#{finding[:finding]}`"] }
                   .then { |rows| rows.empty? ? nil : table(%w[Endpoint Finding], rows) }
      end

      def regression_rows
        rows = @comparison.regressions.map do |delta|
          [delta.endpoint, delta.metric, delta.before, delta.after, change_text(delta)]
        end

        rows.empty? ? nil : table(["Endpoint", "Metric", "Before", "After", "Change"], rows)
      end

      # BEFORE "Resolved", deliberately. An endpoint that became unmeasurable has lost
      # its findings in the arithmetic, and a reader who meets the resolved list first
      # concludes their fix worked.
      def transition_rows
        rows = @comparison.transitions.map { |t| [t.endpoint, t.before, t.after, t.note] }

        rows.empty? ? nil : table(%w[Endpoint Before After Note], rows)
      end

      def resolved_rows
        rows = @comparison.resolved_findings.map do |finding|
          [finding[:endpoint], "`#{finding[:finding]}`",
           finding[:resolved] ? "fixed" : "NOT a fix — #{finding[:note]}"]
        end

        rows.empty? ? nil : table(%w[Endpoint Finding Outcome], rows)
      end

      def unattributable_rows
        rows = @comparison.unattributable.map do |delta|
          [delta.endpoint, delta.metric, delta.before, delta.after, change_text(delta), delta.note]
        end

        rows.empty? ? nil : table(["Endpoint", "Metric", "Before", "After", "Change", "Why not"], rows)
      end

      def noise_rows
        rows = @comparison.within_noise.map do |delta|
          [delta.endpoint, delta.metric, delta.before, delta.after, change_text(delta)]
        end

        rows.empty? ? nil : table(["Endpoint", "Metric", "Before", "After", "Change"], rows)
      end

      def endpoint_set_block
        added = @comparison.endpoints_added
        removed = @comparison.endpoints_removed
        return "" if added.empty? && removed.empty?

        ["## Endpoint set", "",
         added.empty? ? nil : "Added: #{added.map { |e| "`#{e}`" }.join(', ')}",
         removed.empty? ? nil : "Removed: #{removed.map { |e| "`#{e}`" }.join(', ')}"].compact.join("\n")
      end

      def change_text(delta)
        return "" if delta.change.nil?

        "#{(delta.change * 100).round(1)}%"
      end

      def section(title, body, empty:, note: nil)
        return "" if body.nil? && empty.nil?

        parts = ["## #{title}", ""]
        parts << note if note && body
        parts << "" if note && body
        parts << (body || empty)
        parts.join("\n")
      end

      def table(headers, rows)
        lines = ["| #{headers.join(' | ')} |", "|#{headers.map { '---' }.join('|')}|"]
        lines += rows.map { |row| "| #{row.map { |cell| escape(cell) }.join(' | ')} |" }
        lines.join("\n")
      end

      def escape(value) = value.to_s.gsub("|", "\\|").gsub("\n", " ")

      def stylesheet
        <<~CSS
          :root { --bg: #ffffff; --fg: #1b1f24; }
          @media (prefers-color-scheme: dark) { :root { --bg: #12161a; --fg: #e6edf3; } }
          body { margin: 0; background: var(--bg); color: var(--fg); }
          main { max-width: 60rem; margin: 0 auto; padding: 2rem 1.25rem; }
          pre.markdown { white-space: pre-wrap; word-break: break-word;
                         font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; }
        CSS
      end
    end
  end
end
