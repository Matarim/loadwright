# Reporting — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


The report is the actual deliverable a developer reads. Everything else in
the gem exists to produce good data for this. Build it against real sample
data, not just fixtures — open the HTML output in a browser before calling
this subsystem done.

## Formats

- **HTML** (`config.report_formats` includes `:html`) — the primary,
  default format. Self-contained: inline CSS/JS, no external CDN
  dependency, so it opens correctly offline or when shared as a single
  file. This is the one to invest the most design effort in.
- **Markdown** — for pasting into a PR description or Slack; same content,
  tables instead of interactive charts.
- **JSON** — raw structured data, one object per run, for anyone who wants
  to build their own tooling on top or diff two runs programmatically.

All three are generated from the same internal run-result data structure —
don't let formatting logic leak into the data-collection code.

## Redaction — reports contain sensitive data by default

A report includes request bodies, response bodies, SQL, and bind values
drawn from a database that may hold production-shaped data. It gets
written to `tmp/`, where it can be committed, attached to a ticket, or
pasted into Slack. Every APM sanitizes queries before storing them; we
must too, and the sanitizing has to happen **at collection time**, not at
render time, so sensitive values never reach the persisted run record
either.

Defaults:

- Honor `Rails.application.config.filter_parameters` for request params —
  the app has already declared what's sensitive; use it.
- Redact `Authorization`, `Cookie`, `Set-Cookie`, and any header matching
  `config.redact_header_patterns`.
- Replace SQL bind values with placeholders. Query *shape* is what matters
  for every finding this tool produces; the actual values are never
  needed.
- `config.include_response_bodies` defaults to `false` — record size,
  shape, and record counts rather than content. Bodies are opt-in for
  debugging.
- `config.redact_additional_patterns` for app-specific cases (internal
  IDs, tokens in URLs).

### Two places redaction has to reach that aren't obvious

The `reason` strings inside `Measurement.unavailable(...)` and the `cause`
fields on `CapabilityProfile` downgrade events. Both read as internal
metadata, which is exactly why they get treated as exempt — and both are
free text written by the code that just failed, which knows precisely the
things worth protecting: the target URL, the database host, the path the
secret file was at, the account the process runs as. Both are persisted into
every run record and rendered into every report, so they go through the same
redaction path as everything else.

What survives that pass, deliberately:

- **Loopback hosts.** "the app at `http://127.0.0.1:52341` did not become
  healthy" is the entire value of the message and names nothing private. It
  is the *non*-loopback host that can name a company's internal
  infrastructure. Over-redaction that hides why a signal is missing is its
  own failure — a reason that no longer explains anything still *looks* like
  an answer.
- **An ordinary mention of a sensitive word.** "no auth token was
  configured" survives; `token=sk-live-abc` does not. The pattern is
  anchored on the assignment, not on the word.

Home directories are replaced with `~` (the path is the useful part; the
account name is not), and URL credentials go unconditionally.

One entry point (`Redactor#document`) walks the whole run record, so a field
added anywhere downstream is covered by default rather than by someone
remembering to redact it. The **exemplar SQL** kept for `EXPLAIN` (see
`performance-signals.md`) is dropped outright rather than sanitised: nothing
in a report is built from it, the fingerprint is.

The generator adds `config.report_output_dir` and `run_history_dir` to
`.gitignore`, and the report carries a short header noting it may contain
sensitive data and should be treated accordingly.

## Required sections

### 1. Run metadata (top of every report)

- Timestamp, git SHA (if available), Rails env detected, config snapshot
  (the resolved config values actually used, not just "see initializer")
- **Execution mode** (`:in_process` or `:http`), prominently — it
  determines which findings are even measurable, and a reader must never
  have to guess which one produced the numbers they're looking at
- Machine fingerprint (CPU count, memory, Ruby and database versions), for
  run comparison
- Every safety-guard decision made (see `production-safety.md`
  "Auditability") — which environment check passed, whether production
  opt-in was used, whether the circuit breaker tripped and when
- Scale factors and concurrency levels tested
- Total endpoints discovered, broken down by source (OpenAPI /
  integration-spec / route-only) and how many were skipped and why
- Baseline database health check result (see `resource-contention.md`)

**A run that aborts partway must still write a report** with everything
collected up to that point (`config.write_partial_report_on_abort`),
clearly marked as partial. An aborted run producing no output at all is a
bug — the abort itself is often the most interesting finding.

### 2. Summary — worst offenders first

A ranked table, not a wall of per-endpoint sections nobody will read top to
bottom. Rank by a combination of severity signals:

- Endpoints with a detected N+1 (either signal — pattern-match or slope)
- Endpoints that blew their `p95_latency_budget_ms`
- Endpoints with the highest memory allocation per request
- Endpoints where connection pool utilization peaked highest

### 3. Per-endpoint detail

Every endpoint carries one of **three states** — `healthy`,
`has findings`, or `inconclusive` — and they must be visually distinct.
`inconclusive` means "we could not safely or validly measure this"
(response failed the validity gate, or contention forced a quarantine),
and it must never be collapsed into either of the other two. See
`response-analysis.md`.

For each endpoint that had any finding (skip endpoints with nothing
notable — link to a "clean endpoints" appendix instead, don't bury signal
in noise):

- Latency percentiles (p50/p95/p99) at each concurrency level, as a
  small table or sparkline
- Query count vs. scale factor (table + slope verdict — flat / linear /
  worse)
- If N+1 pattern-matched: the offending query fingerprint and the call
  stack / source location, same style Bullet/Prosopite output
- Slowest individual raw SQL statement observed, with `EXPLAIN` output if
  `config.track_pg_stat_statements` is on and the adapter is Postgres
  (via Marginalia-style tagging if available, to confirm attribution)
- Top memory-allocating line/method for that endpoint, if available
- **Where the time went** — the stacked db / view / GC / external / other
  breakdown from `performance-signals.md`, with the containment-skew
  disclosure. An endpoint that is 80% serialization must not read as a
  database problem.
- **Cold vs warm** figures and their delta
- **EXPLAIN findings** for the slowest queries — sequential scans, disk
  sorts, poor selectivity — with the endpoint that caused them
- **Sample count alongside every percentile**, and omission (with the
  required N stated) of any percentile the sample size can't support
- Connection pool high-water mark during that endpoint's testing, plus the
  static pool-vs-server-threads sizing check
- **Response-derived signals** (see `response-analysis.md`): queries per
  returned record, response payload size and its growth across scale
  factors, over-fetch hints (clearly labelled as hints), schema validation
  result, and — where an N+1 was found — the serializer or template it
  originates in, not just the raw stack

### 4. Contention & backoff log

Its own section, because "we couldn't safely measure this" is a distinct
outcome that must never be silently folded into either "clean" or
"failing." For each event: which endpoint, which signal fired (Tier 1
exception / Tier 2 lock poll / Tier 3 latency degradation), the evidence,
whether the blocking session was **ours or external**, which rung of the
ladder was reached, and what the resulting data means.

Endpoints marked `inconclusive` (external blocker) must be visually
distinct from endpoints marked `quarantined` (our load caused it) — they
mean different things and prompt different actions from the reader.

Also record here which side-effect containment measures were active
(mail, jobs, outbound HTTP), since a run without containment produces
findings that may reflect third-party latency rather than the app's own.

### 5. Skipped / excluded appendix

Everything filtered by `excluded_paths`/`included_paths`, everything
discovered with no usable example, everything skipped because the circuit
breaker tripped before it was reached. Nothing should just silently
disappear — if it's not in the main report, it's listed here with a
reason.

## Pass/fail semantics for scripted use

When `config.fail_on_n_plus_one` or any `p95_latency_budget_ms` entry is
exceeded, the CLI exits non-zero and the report's summary section leads
with a clear PASS/FAIL banner — but remember (per `CLAUDE.md`
"Non-goals") this is meant for a developer running it locally and reading
the output, not as the primary mechanism for CI gating. If someone wants a
hard CI gate, the honest answer is still "use `n_plus_one_control` for
that" — Loadwright's exit code is a convenience, not its main interface.
