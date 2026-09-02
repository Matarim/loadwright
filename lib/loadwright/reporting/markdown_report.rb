# frozen_string_literal: true

require "loadwright/errors"
require "loadwright/reporting/presenter"

module Loadwright
  module Reporting
    # For pasting into a PR description or a Slack thread.
    #
    # Same content as the HTML report, tables instead of bars — and, more importantly,
    # the same honesty. It renders through Presenter for exactly that reason: if HTML
    # renders an unavailable Measurement as its reason and Markdown renders it as an
    # em dash, the Markdown report is the dangerous one, and it is also the one most
    # likely to be pasted somewhere without its context.
    #
    # PASTED SOMEWHERE IS THE POINT, which shapes two decisions:
    #
    #   * The three states are spelled out in words, not colour. A pasted table has no
    #     CSS, so `inconclusive` has to survive as text.
    #   * The sensitivity notice comes first. Someone about to paste this into a
    #     shared channel should see it before they scroll.
    class MarkdownReport
      include Presenter

      FORMAT = :markdown

      STATE_MARKS = { "healthy" => "OK", "has_findings" => "FINDINGS", "inconclusive" => "INCONCLUSIVE" }.freeze

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      def render(result)
        @result = result
        @data = result.to_h
        @metadata = @data[:metadata] || {}

        [
          partial_banner,
          notice,
          header,
          diagnoses,
          summary,
          capability,
          endpoints_section,
          clean_appendix,
          contention,
          warnings_block,
          provenance
        ].compact.reject(&:empty?).join("\n\n")
      end

      def write!(result, path:)
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, render(result))
        path
      end

      private

      def partial_banner
        return "" unless @metadata[:aborted]

        "> **Partial run.** This stopped before it finished, so the endpoints below are not the\n" \
          "> whole API and anything missing was not necessarily clean.\n" \
          "> #{@metadata[:aborted_reason]}"
      end

      def notice
        "> This report may contain data drawn from your database — query shapes, response sizes,\n" \
          "> and endpoint paths. Bind values and filtered parameters are redacted at collection\n" \
          "> time. Check before sharing it."
      end

      def header
        rows = {
          "Execution mode" => @metadata[:execution_mode],
          "Transport → collector" => "#{@metadata[:transport]} → #{@metadata[:collector]}",
          "Environment" => @metadata.dig(:safety, :environment),
          "Git" => git_text,
          "Scale factors" => Array(config_value(:scale_factors)).join(", "),
          "Concurrency" => Array(config_value(:concurrency_levels)).join(", "),
          "Requests per cell" => config_value(:requests_per_endpoint_per_level),
          "Duration" => duration(@metadata[:duration_seconds])
        }

        ["# Loadwright — #{@metadata[:started_at]}", "", definition_rows(rows), containment_line].compact.join("\n")
      end

      def git_text
        sha = @metadata.dig(:git, :sha) || @metadata[:git_sha]
        return nil if sha.nil?

        "#{sha}#{@metadata.dig(:git, :dirty) ? ' (dirty worktree)' : ''}"
      end

      def containment_line
        summary = @metadata.dig(:containment_disclosure, :summary)
        summary && "\n_#{summary}_"
      end

      def diagnoses
        Array(@metadata[:traffic]).map { |d| "> **#{d[:kind]}** — #{d[:message]}" }.join("\n\n")
      end

      def summary
        counts = @data[:summary] || {}
        inconclusive = counts[:inconclusive].to_i

        lines = [
          "## Summary",
          "",
          "| healthy | with findings | inconclusive |",
          "|---:|---:|---:|",
          "| #{counts[:healthy].to_i} | #{counts[:has_findings].to_i} | #{inconclusive} |",
          ""
        ]

        unless inconclusive.zero?
          lines << "#{pluralise(inconclusive, 'endpoint')} did not produce a verdict" \
                   "#{inconclusive_breakdown}. " \
                   "#{inconclusive == 1 ? 'It is' : 'They are'} **not** counted as passing."
          lines << ""
        end

        lines << ranked_table
        lines.join("\n")
      end

      def ranked_table
        rows = @result.ranked_findings
        return "_No findings._" if rows.empty?

        table(
          %w[Endpoint Finding Confidence Detail],
          rows.map do |entry|
            finding = entry[:finding]
            finding = finding.to_h if finding.respond_to?(:to_h)
            [entry[:endpoint], "`#{finding[:kind]}`", finding[:confidence], finding[:detail]]
          end
        )
      end

      # Per window, for the same reason the HTML report does it: one claim for a run
      # that degraded partway is a claim that is false for part of the run.
      def capability
        epochs = capability_epochs(@metadata[:capabilities])
        return "" if epochs.empty?

        parts = ["## What this run could measure"]
        if degraded?(@metadata[:capabilities])
          parts << ""
          parts << "> **Capability degraded mid-run.** #{lost_signals(@metadata[:capabilities]).join(', ')} " \
                   "stopped being measurable partway through. Results are attributed to the window they " \
                   "were collected in."
        end

        epochs.each do |epoch|
          parts << ""
          parts << "### #{epochs.length == 1 ? 'Throughout the run' : "Window #{epoch[:index] + 1}"}"
          parts << "_Entered because: #{epoch[:cause]}_" if epoch[:cause]
          parts << ""
          unavailable = epoch[:signals].reject { |signal| signal[:status] == "available" }
          parts << if unavailable.empty?
                     "Everything Loadwright measures was available."
                   else
                     table(["Signal", "Status", "Why not"],
                           unavailable.map { |s| [s[:name].tr("_", " "), s[:status], s[:reason]] })
                   end
        end

        parts.join("\n")
      end

      def endpoints_section
        notable = endpoints.reject { |endpoint| endpoint[:state].to_s == "healthy" }
        return "" if notable.empty?

        sorted = notable.sort_by { |endpoint| [state_rank(endpoint[:state]), endpoint[:endpoint].to_s] }
        (["## Endpoints"] + sorted.map { |endpoint| endpoint_block(endpoint) }).join("\n\n")
      end

        def endpoint_block(endpoint)
        parts = ["### `#{endpoint[:endpoint]}` — #{STATE_MARKS.fetch(endpoint[:state].to_s, endpoint[:state])}" \
                 "#{status_summary(endpoint)}"]

        if endpoint[:state].to_s == "inconclusive"
          parts << ""
          parts << "**Not measured.** #{endpoint[:explanation]}"
          parts << ""
          parts << "No performance verdict is attached. Its absence from the findings list means " \
                   "nothing was checked — not that nothing is wrong."
        end

        findings = Array(endpoint[:findings])
        # MEASURED, REAL, AND CARRYING NO VERDICT. An inconclusive endpoint's findings
        # were observed on responses that did the work; they are shown under their own
        # heading so nobody reads them as a verdict, and never in the ranked table.
        if endpoint[:state].to_s == "inconclusive" && !findings.empty?
          parts << ""
          parts << "**Measured before this endpoint was set aside** — real, and not a verdict. " \
                   "The endpoint is `inconclusive` for the reason above; these were observed on " \
                   "responses that did the work."
          parts += findings.map do |finding|
            finding = finding.to_h if finding.respond_to?(:to_h)
            "- **`#{finding[:kind]}`** (#{finding[:confidence]}) — #{finding[:detail]}"
          end
          findings = []
        end
        unless findings.empty?
          parts << ""
          parts += findings.map do |finding|
            finding = finding.to_h if finding.respond_to?(:to_h)
            "- **`#{finding[:kind]}`** (#{finding[:confidence]}) — #{finding[:detail]}" \
              "#{finding[:suggestion] ? "\n  - **Try:** #{finding[:suggestion]}" : ''}"
          end
        end

        coverage = endpoint.dig(:coverage, :description)
        parts << "\n_#{coverage}_" unless coverage.to_s.empty?

        parts << sources_block(endpoint)
        parts << schema_block(endpoint)
        parts << sub_threshold_block(endpoint)
        parts << request_block(endpoint)
        parts << breakdown_block(endpoint)
        parts << latency_block(endpoint)
        parts << cells_block(endpoint[:endpoint].to_s)
        parts.compact.reject(&:empty?).join("\n")
      end

      # The cells table is where a STEP-DOWN becomes visible. Omitting it here -- as
      # this format did at first -- means the one format most likely to be pasted
      # somewhere is the one that shows the requested concurrency and never mentions
      # that the cell ran at a lower one.
      def cells_block(key)
        cells = Array(@data[:cells]).select { |cell| cell[:endpoint].to_s == key }
        return "" if cells.empty?

        rows = cells.map do |cell|
          [cell_label(cell), concurrency_text(cell), cell[:records], cell[:queries], cell[:bytes],
           Array(cell[:statuses]).map { |status, count| "#{status}x#{count}" }.join(" "),
           cell[:skipped_reason]]
        end

        ["", "**Cells**", "", table(%w[Cell Concurrency Records Queries Bytes Statuses Note], rows)].join("\n")
      end

      def breakdown_block(endpoint)
        shares = breakdown_shares(endpoint[:time_breakdown])
        return "" if shares.empty?

        rows = shares.map { |share| [share[:label], "#{share[:ms].round(2)}ms", "#{share[:share].round(1)}%"] }
        headline = endpoint.dig(:time_breakdown, :containment, :headline)

        ["", "**Where the time went** — #{endpoint.dig(:time_breakdown, :total_ms).to_f.round(2)}ms total", "",
         table(%w[Component Time Share], rows), headline ? "_#{headline}_" : nil].compact.join("\n")
      end

      def latency_block(endpoint)
        cells = Array(endpoint[:latency])
        return "" if cells.empty?

        shown = cells.flat_map { |cell| percentiles(cell).select { |p| p[:available] }.map { |p| p[:name] } }.uniq
        rows = cells.map do |cell|
          values = percentiles(cell).select { |p| shown.include?(p[:name]) }.map { |p| p[:text] }
          [cell[:label], sample_note(cell), *values]
        end

        omitted = cells.flat_map { |cell| percentiles(cell).reject { |p| shown.include?(p[:name]) } }
                       .filter_map { |percentile| percentile[:reason] }.uniq

        ["", "**Latency**", "", table(["Cell", "Samples", *shown], rows),
         omitted.empty? ? nil : "_Omitted: #{omitted.join(' ')}_"].compact.join("\n")
      end

      def clean_appendix
        clean = endpoints.select { |endpoint| endpoint[:state].to_s == "healthy" }
        return "" if clean.empty?

        (["## Clean endpoints (#{clean.length})", ""] +
          clean.map do |endpoint|
            "- `#{endpoint[:endpoint]}` — #{endpoint.dig(:coverage, :description)}" \
              "#{schema_clause(endpoint)}#{sources_clause(endpoint)}"
          end)
          .join("\n")
      end

      # Its own section, because "we could not safely measure this" must never be
      # folded into either clean or failing.
      def contention
        contention = @metadata[:contention]
        events = Array(contention && contention[:events])
        quarantined = Array(contention && contention[:quarantined])
        return "" if events.empty? && quarantined.empty?

        parts = ["## Contention & backoff", "",
                 "Loadwright retreats from contention and never attempts to resolve it. A blocker of " \
                 "_external_ means the contention was not ours, so nothing here is attributable to " \
                 "the endpoint."]

        unless events.empty?
          parts << ""
          parts << table(%w[Endpoint Signal Blocker Rung Concurrency],
                         events.map { |e| [e[:endpoint], e[:kind], e[:blocker], e[:rung], e[:concurrency]] })
        end

        unless quarantined.empty?
          parts << ""
          parts << "**Quarantined:** #{quarantined.join(', ')} — our own load caused this, and those " \
                   "endpoints were abandoned rather than measured."
        end

        parts.join("\n")
      end

      # RUN WARNINGS WERE RENDERED IN HTML AND NOWHERE ELSE. Every warning the run
      # produced -- a page-size sweep that could not run, a discovery source that found
      # nothing, a containment measure that did not hold -- was invisible to anyone
      # reading the Markdown report, which is the format people paste into a PR and the
      # one an agent reads.
      #
      # Found because a warning added in 0.0.10 was reported as not firing when it had
      # fired: the condition was met and printed on the same page, and the sentence
      # naming it went to a format the reader was not looking at.
      def warnings_block
        warnings = Array(@metadata[:warnings]).compact.reject { |warning| warning.to_s.strip.empty? }
        return "" if warnings.empty?

        (["## Warnings", "",
          "Things this run wants you to know about the run itself, not about an endpoint.", ""] +
          warnings.map { |warning| "- #{warning}" }).join("\n")
      end

      def provenance
        safety = @metadata[:safety]
        containment = @metadata[:containment]
        parts = ["## Run provenance"]

        if safety
          parts << ""
          parts << definition_rows(
            "Approved" => safety[:approved], "Environment" => safety[:environment],
            "In allowlist" => safety[:environment_allowlisted],
            "Production-adjacent" => safety[:production_adjacent],
            "Production opt-in used" => safety[:production_opt_in_used],
            "Mutating requests allowed" => safety[:mutating_requests_allowed]
          )
        end

        if containment
          parts << ""
          parts << "**Side-effect containment**"
          parts << ""
          parts << table(%w[Measure Requested Enforced],
                         Array(containment[:measures]).map { |m| [m[:name], m[:requested], m[:enforced]] })
        end

        parts.join("\n")
      end

      # ------------------------------------------------------------------ helpers

      # WHAT WE ASKED IT. Without this a reader cannot tell a 404 we caused from one the
      # endpoint chose, and cannot tell that two runs measured the same endpoint with
      # different parameters -- which is how a confirmed 73-query finding came back
      # HEALTHY in the next run, with nothing in either report saying the question had
      # changed.
      # WHICH SOURCE WON, PER PATH SEGMENT. A seeded value losing to a recorded literal
      # is invisible otherwise -- the path looks fine and the run says nothing.
      PATH_SOURCES = {
        "override" => "from path_param_overrides",
        "seeded" => "from a seeded record",
        "recorded" => "**replayed from your specs** — a seeded value did not match this parameter's name",
        "example" => "**from the OpenAPI example** — no seeded or recorded value matched"
      }.freeze

      VALUE_SOURCES = {
        "seeded" => "from a seeded record",
        "recorded" => "replayed from your specs",
        "recorded_identifier" => "**replayed from your specs, unresolved**",
        "page_size_sweep" => "set by the page-size sweep"
      }.freeze

      # SUCCEEDED HERE, FAILED THERE. A single verdict on the header while four of six
      # cells answered 200 makes a reader open the cell table to find out what
      # happened. Rendered inline, and omitted entirely when every request agreed.
      def status_summary(endpoint)
        counts = Hash(endpoint[:statuses])
        return "" if counts.length < 2

        " (#{counts.map { |status, count| "#{count} x #{status}" }.join(', ')})"
      end

      # NOT A FINDING, AND NOT INVISIBLE EITHER. An endpoint that issued the same query
      # twice per request used to look identical to one that issued it once.
      # SCHEMA VALIDITY IS NOT IN THE COVERAGE LINE, so it gets its own. It belongs to
      # the validity gate rather than to a finding class, and a setting whose whole
      # purpose is to stop an endpoint being called healthy on a response that is not
      # what it claims must not be silent about whether it ran.
      SCHEMA_LABELS = {
        "validated" => "Response schema: checked, no violations.",
        "no_document_match" => "Response schema: not checked.",
        "unresolvable" => "Response schema: NOT CHECKED — a Loadwright fault, not yours.",
        "no_schema" => "Response schema: not checked.",
        "violations" => "Response schema: violations found."
      }.freeze

      # A CLEAN ENDPOINT GETS ONE LINE, and it is the line a reader trusts most, so the
      # schema answer has to fit on it. This is where the silence was loudest: an
      # endpoint declared healthy, its coverage line naming five checks, and no way to
      # tell whether the sixth ran.
      SCHEMA_CLAUSES = {
        "validated" => " — response schema: checked",
        "no_document_match" => " — response schema: not checked (no document operation matched)",
        "unresolvable" => " — response schema: not checked (Loadwright could not load it)",
        "no_schema" => " — response schema: not checked (matched, none declared)",
        "violations" => " — response schema: violations found"
      }.freeze

      def sources_clause(endpoint)
        sources = Array(endpoint[:sources])
        return "" if sources.empty?

        " — from #{sources.join(', ')}"
      end

      def schema_clause(endpoint)
        state = endpoint.dig(:schema, :state)
        return "" if state.nil?

        SCHEMA_CLAUSES.fetch(state.to_s, "")
      end

      # Tolerates both shapes: a persisted run written before values were recorded
      # carries a bare provenance symbol, and rendering that as a missing value would
      # make an older report look like one that sent nothing.
      def value_source(entry)
        source = entry.is_a?(Hash) ? entry[:source] : entry

        VALUE_SOURCES.fetch(source.to_s, source.to_s)
      end

      def request_value(entry)
        entry.is_a?(Hash) ? entry[:value].inspect : "?"
      end

      def sources_block(endpoint)
        sources = Array(endpoint[:sources])
        return nil if sources.empty?

        "\n_Discovered from: #{sources.join(', ')}._"
      end

      def schema_block(endpoint)
        schema = endpoint[:schema]
        return nil if schema.nil?

        "\n_#{SCHEMA_LABELS.fetch(schema[:state].to_s, 'Response schema:')} #{schema[:note]}._"
      end

      def sub_threshold_block(endpoint)
        summary = endpoint.dig(:correlation, :sub_threshold_duplicates)
        return nil if summary.nil?

        denominator = summary[:queries_in_request] ? " of #{summary[:queries_in_request].round}" : ""

        "\n_Repeated queries seen, below the finding threshold: the most repeated ran " \
          "#{summary[:occurrences]}x in one request#{denominator} (threshold #{summary[:threshold]})._"
      end

      def request_block(endpoint)
        shape = endpoint[:request]
        return nil if shape.nil?

        query = Hash(shape[:query])
        path_values = Hash(shape[:path_values])
        return nil if query.empty? && path_values.empty?

        rows = path_values.map do |name, source|
          "  - `{#{name}}` — #{PATH_SOURCES.fetch(source.to_s, source.to_s)}"
        end
        rows += query.map do |name, entry|
          "  - `#{name}` = `#{request_value(entry)}` — #{value_source(entry)}"
        end

        (["", "**Request sent:** `#{shape[:path]}`"] + rows).join("\n")
      end

      def endpoints = Array(@data[:endpoints])

      # DECLINED IS NOT UNMEASURABLE. Reported apart so a reader improving coverage can
      # see which part of the number is a config switch away.
      def inconclusive_breakdown
        summary = Hash(@data[:summary])
        declined = summary[:declined].to_i
        return "" if declined.zero?

        " (#{summary[:not_measurable].to_i} could not be measured, #{declined} declined by " \
          "configuration and never requested)"
      end

      def config_value(key) = @metadata.dig(:config, key, :value)

      def definition_rows(rows)
        usable = rows.reject { |_, value| value.nil? || value.to_s.empty? }
        table(%w[Item Value], usable.map { |label, value| [label, value] })
      end

      # A cell containing a pipe would silently break the table, and a broken table in
      # a pasted report looks like a bug in the tool rather than in the escaping.
      def table(headers, rows)
        lines = ["| #{headers.join(' | ')} |", "|#{headers.map { '---' }.join('|')}|"]
        lines += rows.map { |row| "| #{row.map { |cell| escape(cell) }.join(' | ')} |" }
        lines.join("\n")
      end

      def escape(value) = value.to_s.gsub("|", "\\|").gsub("\n", " ")
    end
  end
end
