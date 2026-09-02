# frozen_string_literal: true

require "cgi"
require "json"
require "loadwright/errors"
require "loadwright/reporting/presenter"

module Loadwright
  module Reporting
    # The primary deliverable — the thing a developer actually reads.
    #
    # SELF-CONTAINED BY REQUIREMENT, not by preference. Inline CSS and JS, no CDN,
    # no external font. A report gets emailed, attached to a ticket, and opened on a
    # laptop on a train; one that needs the network to render is one that renders
    # blank exactly when someone is trying to use it.
    #
    # WHAT THIS FILE IS NOT ALLOWED TO DO, because the rendering layer is the last
    # place these can go wrong and the easiest place to lose them:
    #
    #   * BRANCH ON THE EXECUTION MODE. It renders from the capability record and
    #     from Measurement. The mode is DISPLAYED in the metadata header, which is
    #     a display read of a value already in the hash -- reporting never touches
    #     config. A spec greps for this.
    #
    #   * CLAIM ONE CAPABILITY FOR THE WHOLE RUN. Capability degrades mid-run, so
    #     the header renders every epoch with the cause of each downgrade. A single
    #     "this mode supports X" banner is a lie in precisely the runs where a
    #     wrong claim does the most damage.
    #
    #   * RENDER AN UNAVAILABLE MEASUREMENT AS A DASH OR A ZERO. It renders the
    #     reason. See Presenter.
    #
    #   * MAKE `inconclusive` LOOK LIKE `healthy`. Three states, three colours,
    #     three labels, and the summary counts them separately.
    class HtmlReport
      include Presenter

      FORMAT = :html

      def initialize(config: Loadwright.configuration)
        @config = config
      end

      def render(result)
        @result = result
        @data = result.to_h
        @metadata = @data[:metadata] || {}

        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Loadwright — #{h(@metadata[:started_at])}</title>
          <style>#{stylesheet}</style>
          </head>
          <body>
          <main>
          #{partial_banner}
          #{sensitivity_notice}
          #{header}
          #{run_diagnoses}
          #{summary}
          #{capability_section}
          #{endpoint_sections}
          #{clean_appendix}
          #{contention_section}
          #{skipped_appendix}
          #{provenance_section}
          </main>
          <script>#{script}</script>
          </body>
          </html>
        HTML
      end

      def write!(result, path:)
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, render(result))
        path
      end

      private

      def h(value) = CGI.escapeHTML(value.to_s)

      # ------------------------------------------------------------------ banners

      # An aborted run still writes a report, and it has to say so at the top. The
      # abort is usually the most interesting finding in it, and a partial report
      # mistaken for a complete one under-reports the API silently.
      def partial_banner
        return "" unless @metadata[:aborted]

        <<~HTML
          <div class="banner banner-partial">
            <strong>Partial run.</strong> This run stopped before it finished, so the endpoints below
            are not the whole API and anything missing was not necessarily clean.
            <div class="banner-detail">#{h(@metadata[:aborted_reason])}</div>
          </div>
        HTML
      end

      def sensitivity_notice
        <<~HTML
          <div class="banner banner-notice">
            This report may contain data drawn from your database — query shapes, response sizes,
            and endpoint paths. Bind values and configured filter parameters are redacted at
            collection time. Check before sharing it.
          </div>
        HTML
      end

      # ------------------------------------------------------------------- header

      def header
        <<~HTML
          <header>
            <h1>Loadwright</h1>
            <p class="subtitle">#{h(@metadata[:started_at])} · #{h(duration(@metadata[:duration_seconds]))}</p>
            <dl class="meta">
              #{meta_item('Execution mode', execution_mode_text)}
              #{meta_item('Transport → collector', "#{@metadata[:transport]} → #{@metadata[:collector]}")}
              #{meta_item('Environment', safety_dig(:environment))}
              #{meta_item('Git', git_text)}
              #{meta_item('Scale factors', Array(config_value(:scale_factors)).join(', '))}
              #{meta_item('Concurrency', Array(config_value(:concurrency_levels)).join(', '))}
              #{meta_item('Requests per cell', config_value(:requests_per_endpoint_per_level))}
              #{meta_item('Loadwright', @metadata[:loadwright_version])}
            </dl>
            #{containment_note}
          </header>
        HTML
      end

      # The mode is a value in the metadata hash, put there by RunResult. Displayed
      # prominently because a reader must never have to guess which mode produced the
      # numbers they are looking at.
      def execution_mode_text = @metadata[:execution_mode].to_s

      def meta_item(label, value)
        return "" if value.to_s.strip.empty?

        "<div><dt>#{h(label)}</dt><dd>#{h(value)}</dd></div>"
      end

      def git_text
        sha = @metadata.dig(:git, :sha) || @metadata[:git_sha]
        return "" if sha.nil?

        dirty = @metadata.dig(:git, :dirty) ? " (dirty worktree)" : ""
        "#{sha}#{dirty}"
      end

      # REQUIRED, not optional. Containment makes the app faster than production
      # reality and the missing time appears in no component at all, so nothing in
      # the numbers hints at it.
      def containment_note
        disclosure = @metadata[:containment_disclosure]
        return "" if disclosure.nil? || disclosure[:summary].nil?

        css = disclosure[:skewed] ? "note note-warn" : "note"
        "<p class=\"#{css}\">#{h(disclosure[:summary])}</p>"
      end

      # ------------------------------------------------------- run-level diagnoses

      # The one sentence that explains a report full of `inconclusive`. It goes above
      # the summary deliberately: a reader looking at twelve unmeasurable endpoints
      # needs the cause before the list, not after it.
      def run_diagnoses
        diagnoses = Array(@metadata[:traffic])
        return "" if diagnoses.empty?

        items = diagnoses.map do |diagnosis|
          "<div class=\"banner banner-diagnosis\"><strong>#{h(diagnosis[:kind])}</strong> " \
            "#{h(diagnosis[:message])}</div>"
        end

        items.join("\n")
      end

      # ------------------------------------------------------------------ summary

      def summary
        counts = @data[:summary] || {}

        <<~HTML
          <section id="summary">
            <h2>Summary</h2>
            <div class="counts">
              #{count_tile('healthy', counts[:healthy], 'state-healthy')}
              #{count_tile('with findings', counts[:has_findings], 'state-has-findings')}
              #{count_tile('inconclusive', counts[:inconclusive], 'state-inconclusive')}
            </div>
            <p class="note">#{h(clean_note(counts))}</p>
            #{ranked_table}
          </section>
        HTML
      end

      def count_tile(label, value, css)
        "<div class=\"tile #{css}\"><span class=\"tile-value\">#{h(value.to_i)}</span>" \
          "<span class=\"tile-label\">#{h(label)}</span></div>"
      end

      # "18 endpoints clean" is a lie if 12 of them were inconclusive. The wording
      # here is the reason `clean` means `healthy` in the data model rather than
      # "not has_findings".
      def clean_note(counts)
        inconclusive = counts[:inconclusive].to_i
        return "#{pluralise(counts[:healthy].to_i, 'endpoint')} measured clean." if inconclusive.zero?

        "#{pluralise(counts[:healthy].to_i, 'endpoint')} measured clean. " \
          "#{pluralise(inconclusive, 'endpoint')} #{inconclusive == 1 ? 'was' : 'were'} not validly " \
          "measurable and #{inconclusive == 1 ? 'is' : 'are'} NOT counted as passing — see the " \
          "sections below for why."
      end

      # Worst offenders first. Drawn only from endpoints that were measured: an
      # inconclusive endpoint has no position in a ranking, and including one would
      # put a 403 at whichever end its 4ms latency landed.
      def ranked_table
        rows = @result.ranked_findings
        return "<p class=\"note\">No findings.</p>" if rows.empty?

        body = rows.map do |entry|
          finding = entry[:finding]
          finding = finding.to_h if finding.respond_to?(:to_h)
          <<~ROW
            <tr>
              <td><a href="##{h(anchor(entry[:endpoint]))}">#{h(entry[:endpoint])}</a></td>
              <td><span class="kind">#{h(finding[:kind])}</span></td>
              <td class="confidence-#{h(finding[:confidence])}">#{h(finding[:confidence])}</td>
              <td>#{h(finding[:detail])}</td>
            </tr>
          ROW
        end

        table(%w[Endpoint Finding Confidence Detail], body.join)
      end

      # --------------------------------------------------------------- capability

      # Rendered as a TIMELINE, not a single claim. Where a run never degraded this
      # is one window and reads as one claim; where it did, the reader sees which
      # results were collected under which capability and what caused the change.
      def capability_section
        capabilities = @metadata[:capabilities]
        return "" if capabilities.nil?

        epochs = capability_epochs(capabilities)
        return "" if epochs.empty?

        <<~HTML
          <section id="capability">
            <h2>What this run could measure</h2>
            #{degradation_warning(capabilities)}
            #{epochs.map { |epoch| capability_window(epoch, epochs.length) }.join("\n")}
          </section>
        HTML
      end

      def degradation_warning(capabilities)
        return "" unless degraded?(capabilities)

        lost = lost_signals(capabilities)
        <<~HTML
          <div class="banner banner-partial">
            <strong>Capability degraded mid-run.</strong>
            #{h(lost.join(', '))} stopped being measurable partway through. Results are attributed to
            the window they were collected in — a signal reported below may be trustworthy for the
            earlier requests and absent for the later ones.
          </div>
        HTML
      end

      def capability_window(epoch, total)
        title = total == 1 ? "Throughout the run" : "Window #{epoch[:index] + 1}"
        cause = epoch[:cause] ? "<p class=\"note note-warn\">Entered because: #{h(epoch[:cause])}</p>" : ""

        rows = epoch[:signals].map do |signal|
          "<tr class=\"cap-#{h(signal[:status])}\"><td>#{h(signal[:name].tr('_', ' '))}</td>" \
            "<td>#{h(signal[:status])}</td><td>#{h(signal[:reason])}</td></tr>"
        end

        <<~HTML
          <details class="window"#{epoch[:cause] ? ' open' : ''}>
            <summary>#{h(title)} — from #{h(epoch[:started_at])}</summary>
            #{cause}
            #{table(["Signal", "Status", "Why not"], rows.join)}
          </details>
        HTML
      end

      # -------------------------------------------------------------- per endpoint

      def endpoint_sections
        notable = endpoints.reject { |endpoint| endpoint[:state].to_s == "healthy" }
        return "" if notable.empty?

        sorted = notable.sort_by { |endpoint| [state_rank(endpoint[:state]), endpoint[:endpoint].to_s] }

        "<section id=\"endpoints\"><h2>Endpoints</h2>\n#{sorted.map { |e| endpoint_section(e) }.join("\n")}</section>"
      end

      def endpoint_section(endpoint)
        key = endpoint[:endpoint].to_s

        <<~HTML
          <article class="endpoint #{h(state_class(endpoint[:state]))}" id="#{h(anchor(key))}">
            <h3>#{h(key)} <span class="badge">#{h(state_label(endpoint[:state]))}</span>#{status_summary(endpoint)}</h3>
            #{inconclusive_explanation(endpoint)}
            #{findings_list(endpoint)}
            #{coverage_note(endpoint)}
            #{sources_note(endpoint)}
            #{schema_note(endpoint)}
            #{sub_threshold_note(endpoint)}
            #{request_block(endpoint)}
            #{time_breakdown(endpoint)}
            #{latency_table(endpoint)}
            #{cells_table(key)}
            #{cold_warm(endpoint)}
            #{explain_block(endpoint)}
          </article>
        HTML
      end

      # `inconclusive` means "we could not safely or validly measure this", and the
      # reason is the only actionable thing on the section. It goes first.
      def inconclusive_explanation(endpoint)
        return "" unless endpoint[:state].to_s == "inconclusive"

        # THE SENTENCE HAS TO KNOW WHAT IS PRINTED BELOW IT. Where findings were
        # retained, "its absence from the findings list" is contradicted by the findings
        # themselves a few lines later.
        note = if Array(endpoint[:findings]).any?
                 "No performance <strong>verdict</strong> is attached to this endpoint and it is not " \
                   "counted as passing. What was measured before it was set aside is printed below: " \
                   "those findings are real. Anything not listed was not checked."
               else
                 "No performance verdict is attached to this endpoint. It is not counted as passing, " \
                   "and its absence from the findings list means nothing was checked — not that " \
                   "nothing is wrong."
               end

        <<~HTML
          <div class="explanation">
            <strong>Not measured.</strong> #{h(endpoint[:explanation])}
            <p class="note">#{note}</p>
          </div>
        HTML
      end

      def findings_list(endpoint)
        findings = Array(endpoint[:findings])
        return "" if findings.empty?

        items = findings.map do |finding|
          finding = finding.to_h if finding.respond_to?(:to_h)
          "<li class=\"confidence-#{h(finding[:confidence])}\"><span class=\"kind\">#{h(finding[:kind])}</span>" \
            "<span class=\"detail\">#{h(finding[:detail])}</span>" \
              "#{suggestion_html(finding)}</li>"
        end

        list = "<ul class=\"findings\">#{items.join}</ul>"
        return list unless endpoint[:state].to_s == "inconclusive"

        # MEASURED, REAL, AND CARRYING NO VERDICT. Observed on responses that did the
        # work, on an endpoint that could not be judged for an unrelated reason. Given
        # its own heading so nobody reads it as a verdict.
        "<p class=\"note\"><strong>Measured before this endpoint was set aside</strong> — real, " \
          "and not a verdict. The endpoint is inconclusive for the reason above; these were " \
          "observed on responses that did the work.</p>#{list}"
      end

      # Visually subordinate to the finding, and labelled "Try", because it is a
      # starting point read off a query shape rather than a verdict about the code.
      def suggestion_html(finding)
        return "" if finding[:suggestion].to_s.empty?

        "<span class=\"suggestion\"><strong>Try:</strong> #{h(finding[:suggestion])}</span>"
      end

      # REPORTED ON EVERY ENDPOINT, whatever its state. A reader can then see that an
      # otherwise-clean endpoint was checked with one N+1 detector instead of two,
      # without `inconclusive` having to be overloaded to signal it.
      # WHAT WE ASKED IT. Without this a reader cannot tell a 404 we caused from one the
      # endpoint chose, and cannot tell that two runs measured the same endpoint with
      # different parameters -- which is how a confirmed 73-query finding came back
      # HEALTHY in the next run with nothing in either report saying the question had
      # changed.
      VALUE_SOURCES = {
        "seeded" => "from a seeded record",
        "recorded" => "replayed from your specs",
        "recorded_identifier" => "replayed from your specs, unresolved",
        "page_size_sweep" => "set by the page-size sweep"
      }.freeze

      # SUCCEEDED HERE, FAILED THERE. One verdict on the header while four of six cells
      # answered 200 makes a reader open the cell table to find out what happened.
      # Omitted entirely when every request agreed.
      def status_summary(endpoint)
        counts = Hash(endpoint[:statuses])
        return "" if counts.length < 2

        rendered = counts.map { |status, count| "#{count}&times;#{h(status)}" }.join(", ")
        " <span class=\"statuses\">#{rendered}</span>"
      end

      # NOT A FINDING, AND NOT INVISIBLE EITHER.
      def sub_threshold_note(endpoint)
        summary = endpoint.dig(:correlation, :sub_threshold_duplicates)
        return "" if summary.nil?

        denominator = summary[:queries_in_request] ? " of #{h(summary[:queries_in_request].round)}" : ""

        "<p class=\"note coverage\">Repeated queries seen, below the finding threshold: the most " \
          "repeated ran #{h(summary[:occurrences])}&times; in one request#{denominator} " \
          "(threshold #{h(summary[:threshold])}).</p>"
      end

      def request_block(endpoint)
        shape = endpoint[:request]
        return "" if shape.nil?

        query = Hash(shape[:query])
        return "" if query.empty?

        rows = query.map do |name, entry|
          "<li><code>#{h(name)}</code> = <code>#{h(request_value(entry))}</code> — " \
            "#{h(value_source(entry))}</li>"
        end

        "<details class=\"request\"><summary>Request sent: <code>#{h(shape[:path])}</code></summary>" \
          "<ul>#{rows.join}</ul></details>"
      end

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
      # schema answer has to fit on it.
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
      # carries a bare provenance symbol.
      def value_source(entry)
        source = entry.is_a?(Hash) ? entry[:source] : entry

        VALUE_SOURCES.fetch(source.to_s, source.to_s)
      end

      def request_value(entry)
        entry.is_a?(Hash) ? entry[:value].inspect : "?"
      end

      def sources_note(endpoint)
        sources = Array(endpoint[:sources])
        return "" if sources.empty?

        "<p class=\"note coverage\">Discovered from: #{h(sources.join(', '))}.</p>"
      end

      def schema_note(endpoint)
        schema = endpoint[:schema]
        return "" if schema.nil?

        label = SCHEMA_LABELS.fetch(schema[:state].to_s, "Response schema:")

        "<p class=\"note coverage\">#{h(label)} #{h(schema[:note])}</p>"
      end

      def coverage_note(endpoint)
        description = endpoint.dig(:coverage, :description)
        return "" if description.to_s.empty?

        "<p class=\"note coverage\">#{h(description)}</p>"
      end

      # A STACKED BAR, not four numbers in a row. An endpoint that is 80%
      # serialisation must not read as a database problem, and the shape is what
      # makes that legible at a glance.
      def time_breakdown(endpoint)
        breakdown = endpoint[:time_breakdown]
        shares = breakdown_shares(breakdown)
        return "" if shares.empty?

        bars = shares.map do |share|
          "<span class=\"seg seg-#{share[:component]}\" style=\"width:#{share[:share].round(2)}%\" " \
            "title=\"#{h(share[:label])}: #{share[:ms].round(2)}ms\"></span>"
        end

        legend = shares.map do |share|
          "<li><span class=\"swatch seg-#{share[:component]}\"></span>#{h(share[:label])} — " \
            "#{h(share[:ms].round(2))}ms (#{h(share[:share].round(1))}%)</li>"
        end

        <<~HTML
          <div class="breakdown">
            <h4>Where the time went — #{h(breakdown[:total_ms].to_f.round(2))}ms total</h4>
            <div class="bar">#{bars.join}</div>
            <ul class="legend">#{legend.join}</ul>
            #{breakdown_disclosure(breakdown)}
          </div>
        HTML
      end

      # The SHORT form here. The full disclosure is in the header; repeating four
      # sentences under every endpoint's bar pushes the numbers off the screen and
      # trains the reader to skip it, which costs more than the repetition buys.
      def breakdown_disclosure(breakdown)
        containment = breakdown[:containment]
        return "" if containment.nil? || containment[:headline].nil?

        "<p class=\"note #{containment[:skewed] ? 'note-warn' : ''}\">#{h(containment[:headline])} " \
          "<a href=\"#provenance\">What was contained</a></p>"
      end

      # Percentiles with their sample counts, and the unsupported ones OMITTED with
      # what they would have needed.
      # A percentile no cell could support gets its COLUMN dropped and the reason stated
      # once below the table, rather than the same sentence repeated in ten cells. The
      # requirement is that the reason is rendered and the number is not -- repeating it
      # per cell satisfies the letter and buries the figures that ARE supported, which
      # is the opposite of the point.
      def latency_table(endpoint)
        cells = Array(endpoint[:latency])
        return "" if cells.empty?

        shown = supported_percentiles(cells)
        rows = cells.map do |cell|
          columns = percentiles(cell).select { |percentile| shown.include?(percentile[:name]) }
          cell_html = columns.map do |percentile|
            css = percentile[:available] ? "" : " class=\"omitted\""
            text = percentile[:available] ? percentile[:text] : "omitted"
            "<td#{css} title=\"#{h(percentile[:text])}\">#{h(text)}</td>"
          end

          "<tr><td>#{h(cell[:label])}</td><td>#{h(sample_note(cell))}</td>#{cell_html.join}</tr>"
        end

        <<~HTML
          <h4>Latency</h4>
          #{table(['Cell', 'Samples'] + shown, rows.join)}
          #{omitted_percentile_note(cells, shown)}
        HTML
      end

      def supported_percentiles(cells)
        cells.flat_map { |cell| percentiles(cell).select { |p| p[:available] }.map { |p| p[:name] } }.uniq
      end

      def omitted_percentile_note(cells, shown)
        reasons = cells.flat_map { |cell| percentiles(cell).reject { |p| shown.include?(p[:name]) } }
                       .reject { |percentile| percentile[:available] }
                       .filter_map { |percentile| percentile[:reason] }
                       .uniq
        return "" if reasons.empty?

        "<p class=\"note note-warn\">Omitted: #{h(reasons.join(' '))}</p>"
      end

      def cells_table(key)
        rows = cells_for(key).map do |cell|
          <<~ROW
            <tr>
              <td>#{h(cell_label(cell))}</td>
              <td>#{h(concurrency_text(cell))}</td>
              <td>#{h(cell[:records])}</td>
              <td>#{h(cell[:queries])}</td>
              <td>#{h(cell[:bytes])}</td>
              <td>#{h(statuses_text(cell))}</td>
              #{skipped_cell(cell)}
            </tr>
          ROW
        end
        return "" if rows.empty?

        "<h4>Cells</h4>#{table(%w[Cell Concurrency Records Queries Bytes Statuses Note], rows.join)}"
      end

      def skipped_cell(cell)
        return "<td></td>" if cell[:skipped_reason].nil?

        "<td class=\"skipped\">#{h(cell[:skipped_reason])}</td>"
      end

      def statuses_text(cell)
        Array(cell[:statuses]).map { |status, count| "#{status}×#{count}" }.join(" ")
      end

      def cold_warm(endpoint)
        data = endpoint[:cold_warm]
        return "" if data.nil? || data[:cold_ms].nil?

        <<~HTML
          <div class="cold-warm">
            <h4>Cold vs warm (#{h(data[:label])})</h4>
            <p>#{h(data[:cold_ms])}ms cold · #{h(data[:warm_ms])}ms warm#{data[:ratio] ? " · #{h(data[:ratio])}×" : ''}</p>
            <p class="note">#{h(data[:caveat])}</p>
          </div>
        HTML
      end

      def explain_block(endpoint)
        data = endpoint[:explain]
        return "" if data.nil?

        if data[:detector_state].to_s == "unavailable"
          return "<p class=\"note note-warn\">Index analysis unavailable — #{h(data[:detector_reason])}</p>"
        end

        return "" if data[:queries_explained].to_i.zero?

        "<p class=\"note\">EXPLAIN ran on #{pluralise(data[:queries_explained].to_i, 'query', 'queries')} " \
          "via #{h(data[:adapter])}.</p>"
      end

      # ------------------------------------------------------------------ appendix

      # Clean endpoints go in an appendix rather than the main flow. Burying the
      # signal in a wall of per-endpoint sections nobody reads top to bottom is the
      # failure mode reporting.md warns about.
      def clean_appendix
        clean = endpoints.select { |endpoint| endpoint[:state].to_s == "healthy" }
        return "" if clean.empty?

        items = clean.map do |endpoint|
          "<li>#{h(endpoint[:endpoint])}<span class=\"note\">#{h(endpoint.dig(:coverage, :description))}" \
            "#{h(schema_clause(endpoint))}#{h(sources_clause(endpoint))}</span></li>"
        end

        <<~HTML
          <section id="clean">
            <h2>Clean endpoints (#{clean.length})</h2>
            <p class="note">Measured, and nothing notable found. The coverage note says what was checked.</p>
            <ul class="clean-list">#{items.join}</ul>
          </section>
        HTML
      end

      # ITS OWN SECTION, because "we could not safely measure this" is a distinct
      # outcome that must never be folded into either clean or failing. Endpoints
      # blocked by an EXTERNAL session read differently from ones our own load
      # quarantined, and they prompt different actions.
      def contention_section
        contention = @metadata[:contention]
        events = Array(contention && contention[:events])
        return "" if events.empty? && Array(contention && contention[:quarantined]).empty?

        rows = events.map do |event|
          "<tr><td>#{h(event[:endpoint])}</td><td>#{h(event[:kind])}</td><td>#{h(event[:blocker])}</td>" \
            "<td>#{h(event[:rung])}</td><td>#{h(event[:concurrency])}</td></tr>"
        end

        <<~HTML
          <section id="contention">
            <h2>Contention &amp; backoff</h2>
            <p class="note">Loadwright retreats from contention and never attempts to resolve it. A
            blocker of <em>external</em> means the contention was not ours, so nothing here is
            attributable to the endpoint.</p>
            #{rows.empty? ? '' : table(%w[Endpoint Signal Blocker Rung Concurrency], rows.join)}
            #{quarantine_note(contention)}
          </section>
        HTML
      end

      def quarantine_note(contention)
        quarantined = Array(contention && contention[:quarantined])
        return "" if quarantined.empty?

        "<p class=\"note note-warn\">Quarantined after the backoff ladder: #{h(quarantined.join(', '))}. " \
          "Our own load caused this; those endpoints were abandoned rather than measured.</p>"
      end

      # NOTHING SILENTLY DISAPPEARS. If it is not in the main report it is listed
      # here with a reason.
      def skipped_appendix
        skipped = endpoints.select { |endpoint| SKIPPED_REASONS.include?(endpoint[:reason].to_s) }
        warnings = Array(@metadata[:warnings])
        return "" if skipped.empty? && warnings.empty?

        items = skipped.map { |e| "<li>#{h(e[:endpoint])} — #{h(e[:explanation])}</li>" }
        items += warnings.map { |warning| "<li>#{h(warning)}</li>" }

        "<section id=\"skipped\"><h2>Skipped &amp; excluded</h2><ul>#{items.join}</ul></section>"
      end

      SKIPPED_REASONS = %w[circuit_breaker run_aborted interrupted no_example_available].freeze

      # Everything production-safety.md requires be auditable from the report alone,
      # without the terminal scrollback.
      def provenance_section
        <<~HTML
          <section id="provenance">
            <h2>Run provenance</h2>
            #{safety_block}
            #{containment_block}
            #{breaker_block}
            <details>
              <summary>Resolved configuration</summary>
              #{config_table}
            </details>
          </section>
        HTML
      end

      def safety_block
        safety = @metadata[:safety]
        return "" if safety.nil?

        rows = {
          "Approved" => safety[:approved],
          "Environment" => safety[:environment],
          "In allowlist" => safety[:environment_allowlisted],
          "Production-adjacent" => safety[:production_adjacent],
          "Adjacency reasons" => Array(safety[:adjacency_reasons]).join("; "),
          "Production opt-in used" => safety[:production_opt_in_used],
          "Dry run" => safety[:dry_run],
          "Mutating requests allowed" => safety[:mutating_requests_allowed]
        }

        "<h3>Safety</h3>#{definition_table(rows)}"
      end

      def containment_block
        containment = @metadata[:containment]
        return "" if containment.nil?

        rows = Array(containment[:measures]).map do |measure|
          "<tr><td>#{h(measure[:name])}</td><td>#{h(measure[:requested])}</td>" \
            "<td>#{h(measure[:enforced])}</td><td>#{h(measure[:detail])}</td></tr>"
        end
        return "" if rows.empty?

        "<h3>Side-effect containment</h3>#{table(%w[Measure Requested Enforced Detail], rows.join)}"
      end

      def breaker_block
        breaker = @metadata[:circuit_breaker]
        return "" if breaker.nil?

        rows = {
          "Tripped" => breaker[:tripped],
          "Error rate" => breaker[:error_rate],
          "Errors" => breaker[:errors],
          "Observations" => breaker[:observations],
          "Contention events (excluded from the rate)" => breaker[:contention_events],
          # NAMED, WITH COUNTS. Widening an allowlist and getting a pile of quarantines
          # needs to be legible as "these specific endpoints were already broken", not
          # as something the newly added surface did.
          "Quarantined as broken" => quarantined_summary(breaker),
          "Trip reason" => breaker[:trip_reason]
        }.compact

        "<h3>Circuit breaker</h3>#{definition_table(rows)}"
      end

      def quarantined_summary(breaker)
        quarantined = Array(breaker[:quarantined_endpoints])
        return nil if quarantined.empty?

        reasons = breaker[:quarantine_reasons] || {}
        quarantined.map do |key|
          reason = reasons[key] || reasons[key.to_s] || reasons[key.to_sym]
          reason ? "#{key} (#{reason[:errors]}/#{reason[:observations]} failed)" : key.to_s
        end.join(", ")
      end

      def config_table
        config = @metadata[:config] || {}
        rows = config.map do |key, entry|
          entry = symbolize(entry)
          "<tr><td>#{h(key)}</td><td>#{h(entry[:value].inspect)}</td><td>#{h(entry[:from])}</td></tr>"
        end

        table(%w[Key Value From], rows.join)
      end

      # ------------------------------------------------------------------ helpers

      def endpoints = Array(@data[:endpoints])

      def cells_for(key) = Array(@data[:cells]).select { |cell| cell[:endpoint].to_s == key }

      def config_value(key) = @metadata.dig(:config, key, :value)

      def safety_dig(key) = @metadata.dig(:safety, key)

      def anchor(key) = key.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")

      def table(headers, body)
        head = headers.map { |header| "<th>#{h(header)}</th>" }.join
        "<table><thead><tr>#{head}</tr></thead><tbody>#{body}</tbody></table>"
      end

      def definition_table(rows)
        body = rows.filter_map do |label, value|
          next if value.nil? || value.to_s.empty?

          "<tr><td>#{h(label)}</td><td>#{h(value)}</td></tr>"
        end

        table(%w[Item Value], body.join)
      end

      # --------------------------------------------------------------------- assets

      # Inline, and deliberately small. The three state colours are the load-bearing
      # part: `inconclusive` is amber and visually distinct from both green and red,
      # because a reader skimming must never take it for a pass.
      def stylesheet
        <<~CSS
          :root {
            --bg: #ffffff; --fg: #1b1f24; --muted: #5b6570; --line: #dfe3e8; --panel: #f6f8fa;
            --healthy: #1a7f37; --findings: #c0392b; --inconclusive: #b26a00;
            --db: #2c6fbb; --view: #8a4fbd; --gc: #6b7c8c; --other: #c88b2e;
          }
          @media (prefers-color-scheme: dark) {
            :root { --bg: #12161a; --fg: #e6edf3; --muted: #9aa5b1; --line: #2b323a; --panel: #1b2127;
                    --healthy: #3fb950; --findings: #f85149; --inconclusive: #d29922; }
          }
          * { box-sizing: border-box; }
          body { margin: 0; background: var(--bg); color: var(--fg);
                 font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
          main { max-width: 65rem; margin: 0 auto; padding: 2rem 1.25rem 5rem; }
          h1 { font-size: 1.5rem; margin: 0; }
          h2 { font-size: 1.15rem; margin: 2.5rem 0 .75rem; padding-bottom: .35rem;
               border-bottom: 1px solid var(--line); }
          h3 { font-size: 1rem; margin: 1.5rem 0 .5rem; }
          h4 { font-size: .85rem; margin: 1.25rem 0 .4rem; text-transform: uppercase;
               letter-spacing: .04em; color: var(--muted); }
          .subtitle { color: var(--muted); margin: .25rem 0 1rem; }
          .note { color: var(--muted); font-size: .87rem; margin: .4rem 0; }
          .note-warn { color: var(--inconclusive); }
          .banner { padding: .75rem 1rem; border-radius: 6px; margin-bottom: 1rem;
                    border-left: 4px solid var(--line); background: var(--panel); font-size: .9rem; }
          .banner-partial { border-left-color: var(--inconclusive); }
          .banner-diagnosis { border-left-color: var(--findings); }
          .banner-notice { color: var(--muted); }
          .banner-detail { color: var(--muted); margin-top: .35rem; }
          dl.meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
                    gap: .75rem; margin: 1rem 0; }
          dl.meta dt { font-size: .75rem; text-transform: uppercase; letter-spacing: .04em;
                       color: var(--muted); }
          dl.meta dd { margin: .15rem 0 0; font-weight: 600; word-break: break-word; }
          .counts { display: flex; gap: .75rem; flex-wrap: wrap; margin: 1rem 0; }
          .tile { flex: 1 1 8rem; padding: .85rem 1rem; border-radius: 6px; background: var(--panel);
                  border-left: 4px solid var(--line); }
          .tile-value { display: block; font-size: 1.6rem; font-weight: 700; }
          .tile-label { color: var(--muted); font-size: .82rem; }
          .state-healthy { border-left-color: var(--healthy); }
          .state-has-findings { border-left-color: var(--findings); }
          .state-inconclusive { border-left-color: var(--inconclusive); }
          table { border-collapse: collapse; width: 100%; margin: .5rem 0 1rem; font-size: .88rem; }
          th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid var(--line);
                   vertical-align: top; }
          th { font-size: .74rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
          td.omitted { color: var(--inconclusive); font-size: .8rem; }
          td.skipped { color: var(--inconclusive); }
          article.endpoint { border: 1px solid var(--line); border-left-width: 4px; border-radius: 6px;
                             padding: .25rem 1.1rem 1.1rem; margin-bottom: 1.25rem; }
          article.endpoint h3 { display: flex; align-items: center; gap: .6rem; flex-wrap: wrap;
                                font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          .badge { font-family: inherit; font-size: .7rem; text-transform: uppercase; letter-spacing: .05em;
                   padding: .15rem .5rem; border-radius: 999px; background: var(--panel); color: var(--muted); }
          .state-healthy .badge { color: var(--healthy); }
          .state-has-findings .badge { color: var(--findings); }
          .state-inconclusive .badge { color: var(--inconclusive); }
          .statuses { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .75rem;
                      color: var(--muted); margin-left: .4rem; }
          details.request { margin: .5rem 0; font-size: .85rem; color: var(--muted); }
          details.request ul { margin: .4rem 0 .2rem 1.1rem; padding: 0; }
          .explanation { background: var(--panel); border-radius: 6px; padding: .7rem .9rem; margin: .6rem 0; }
          ul.findings { list-style: none; padding: 0; margin: .6rem 0; }
          ul.findings li { padding: .5rem .7rem; border-radius: 5px; background: var(--panel);
                           margin-bottom: .4rem; }
          .kind { display: inline-block; font-family: ui-monospace, monospace; font-size: .78rem;
                  font-weight: 700; margin-right: .5rem; }
          .confidence-high .kind { color: var(--findings); }
          .confidence-low .kind { color: var(--muted); }
          .suggestion { display: block; margin-top: .4rem; padding-left: .7rem;
                        border-left: 2px solid var(--muted); color: var(--muted);
                        font-size: .88rem; }
          .bar { display: flex; height: 1.4rem; border-radius: 4px; overflow: hidden; background: var(--panel); }
          .seg { display: block; }
          .seg-db { background: var(--db); } .seg-view { background: var(--view); }
          .seg-gc { background: var(--gc); } .seg-other { background: var(--other); }
          ul.legend { list-style: none; padding: 0; margin: .5rem 0; display: flex; flex-wrap: wrap;
                      gap: .9rem; font-size: .82rem; color: var(--muted); }
          .swatch { display: inline-block; width: .7rem; height: .7rem; border-radius: 2px;
                    margin-right: .35rem; }
          .clean-list { list-style: none; padding: 0; font-family: ui-monospace, monospace; font-size: .85rem; }
          .clean-list li { padding: .35rem 0; border-bottom: 1px solid var(--line); }
          .clean-list .note { display: block; font-family: initial; }
          details.window { margin: .5rem 0; }
          summary { cursor: pointer; font-size: .9rem; padding: .3rem 0; }
          tr.cap-unavailable td { color: var(--inconclusive); }
          tr.cap-partial td { color: var(--muted); }
          a { color: inherit; }
        CSS
      end

      # Deliberately almost nothing. A report that needs JavaScript to be readable
      # fails the moment it is opened from an email client or a sandboxed viewer.
      def script
        <<~JS
          document.querySelectorAll('table').forEach(function (table) {
            table.addEventListener('click', function () {}, { passive: true });
          });
        JS
      end
    end
  end
end
