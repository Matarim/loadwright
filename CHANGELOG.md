# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.12] — 2026-09-02

### Fixed

- **A schema violation no longer discards findings that were already measured.** 0.0.11
  stopped a schema Loadwright *could not load* from being read as a violation. This is
  the layer underneath: a **genuine** violation still disqualified the endpoint before
  the detectors ran, and everything they had measured went with it.

  The cost was a two-round regression against the tool's own prior output on unchanged
  code — a high-confidence `n_plus_one_pattern_match` (the same query 12 times in a
  single request, of 73 queries in that request) reported correctly in eight
  consecutive rounds, then absent from two, because the operation under-described a
  parameterised response. Silence is indistinguishable from health to anyone who was
  not there for the earlier rounds.

  The validity gate is **not** loosened: "the response did not prove it did the work"
  and "the response did the work and does not match its documentation" are different
  sentences, and only the first justifies throwing measurements away. `:schema_invalid`
  is the only reason that retains findings. An error status, an empty collection where
  records were seeded, a rejected page size and an inconsistent shape all still discard
  them, because those findings describe an error path.

  The state stays `inconclusive` — three states remain load-bearing, coverage really is
  incomplete, and `inconclusive` still never fails the exit code. The findings render
  under their own heading: *"Measured before this endpoint was set aside — real, and not
  a verdict."*

- **A `factory_map` key that matches nothing is no longer silent.** The key is looked up
  under a name derived from the **path parameter**, not from the factory —
  `{caller_number}` looks under `"caller"` — and a key that does not match falls through
  to the recorded literal, producing a run indistinguishable from one with no
  `factory_map` entry at all. One integration configured `value:` correctly, watched 100
  rows seed, saw no warning, and had the recorded literal sent anyway; establishing why
  cost a probe and a cross-round diff.

  The run now names both sides: what was seeded, and what the endpoints actually asked
  for. Each endpoint's request block also shows **which source won for each path
  segment**, so a seeded value losing to a recorded one is visible at a glance.

- **A rejection spec's identifier is no longer replayed.** Recorded path values were
  taken from every capture in a group, including specs asserting that the API *rejects*
  a bad request — which hardcode a deliberately-non-record identifier into the path. The
  recorder captured it faithfully, resolution replayed it, and the endpoint failed on
  every request of every cell, forever.

  **The response status was on disk the whole time.** In one real recording of 600
  requests, 56 carried such a literal and **none had returned 2xx**. Values now come
  only from recordings that succeeded. A template recorded *only* as a rejection keeps
  its route and says so, rather than sending a literal that cannot resolve and reporting
  the resulting 404 as the endpoint's fault.

  This removes two standing workarounds — excluding rejection spec files by name (which
  forces a bad trade when one file carries both a rejection and a healthy case) and
  enumerating the placeholder literals in `excluded_paths` (a property of one team's
  naming that rots the moment somebody invents a new one). Neither needed config, and
  the rule works for every app because it needs no knowledge of anyone's placeholder
  vocabulary.

### Added

- **The page-size sweep reads the values the endpoint declares.** An `enum` on the
  page-size parameter names the legal sizes exactly. 0.0.7 added an outcome reason to
  explain a page size the sweep chose and the endpoint rejected — the right response to
  the symptom, not to the cause. The better answer is not to choose it. The sweep now
  uses the declared set where there is one (bounded by the seeded scale), says so, and
  falls back to `page_size_sweep` where nothing is declared.

## [0.0.11] — 2026-08-31

### Fixed

- **A JSON pointer is not a URI fragment until it is escaped, and json_schemer takes a
  URI.** An OpenAPI path template contains `{` and `}`, which are illegal in a fragment
  unescaped, so resolving the declared schema raised `URI::InvalidURIError` on **every
  operation with a path parameter** — which is most of them.

  The raise was not the damage. It was rescued and returned as a validation *error
  string*, so a fault inside this gem reached the user as **"response did not validate
  against its declared OpenAPI schema"**: twenty endpoints told their responses were
  invalid on the strength of a check that never executed. This is the first release in
  which `require_schema_valid_response` has ever validated anything, and it arrived
  broken.

- **A schema Loadwright could not load no longer discards findings it had already
  measured.** A schema violation disqualifies an endpoint, and a disqualified endpoint
  keeps none of its findings — so the one-line escaping bug above did not merely
  mislabel twenty endpoints, it **deleted three correctly-measured N+1 findings** on
  the way past. A resolution failure is now reported as ours, the response is judged on
  everything else, and no finding is lost for it. A response that genuinely fails a
  schema we *could* load still invalidates the endpoint, unchanged.

- **Run warnings were rendered in HTML and nowhere else.** Every warning a run produced
  — a page-size sweep that could not run, a discovery source that found nothing, a
  containment measure that did not hold — was invisible to anyone reading the Markdown
  report, which is the format people paste into a PR and the one an agent reads.

  Found because a warning added in 0.0.10 was reported as not firing when it *had*
  fired: its condition was met and printed on the same page, and the sentence naming it
  went to a format the reader was not looking at.

- **The query-cache warning said the wrong thing, in the direction that matters.** It
  claimed repeat counts were counts of what executed. They are not: the tracker records
  every query the code issued, cache hit or not, so the N+1 threshold applies to how
  many times the code **asked** and nothing is undercounted. What a live cache actually
  affects is latency, and the `executed` figure printed beside each repeat count. The
  warning now says that.

- **The zero-row query attribution named SQL keywords and truncated identifiers as
  columns.** `IN` with no word boundary matched inside `DISTINCT` and `JOIN`, emitting
  `DIST` and `JO` as column names and truncating real identifiers mid-word — one to a
  single character matching three columns on its own table. It now reads the `WHERE`
  clause only (a join's `ON` keys are join structure, not the filter that excluded the
  rows), anchors word operators, and consumes a table qualifier.

- **The exception behind a 500 is printed on its own**, not only as part of the
  zero-query sentence. An endpoint that reached the database and then raised — which is
  most 500s, and every one that renders a framework error page — named nothing at all.
  A quarantined endpoint is precisely the one whose cause nobody has.

### Added

- **A refusal still reports which endpoints changed verdict.** Refusing to compute
  deltas across a version boundary is right, and that boundary is exactly where a
  verdict is most likely to move because the **tool** changed rather than the
  application — which is when a reader most needs to be told. In one real upgrade
  eighteen endpoints changed verdict, every one for the worse, and the only mechanism
  built to say so could not speak across the boundary where it happened; it was found
  by diffing two reports by hand.

  Verdict membership is a *set fact*, not a measurement: it requires trusting neither
  detector, only the two verdict lists. Every number stays refused.

- **`factory_map` accepts `value:`, a callable for a routing identifier that is not a
  column on the seeded record.** `param:` reaches one attribute; a real API routes on
  values that live two associations away — a customer's phone number, an account's
  external reference — and no column name can express that. `nil` is dropped rather
  than substituted, and a callable that raises warns instead of aborting the run.

- **`before_seed` and `after_run`, for preconditions that are not data.** A feature
  toggle, a setting flipped. `before_seed` runs after the safety gate and containment,
  so anything it touches is inside the run's protections, and before discovery and
  seeding, so a toggle it flips can decide which routes exist. `after_run` is
  registered with the interrupt handler. Neither runs on a dry run, and a `before_seed`
  that raises refuses the run rather than measuring an application in a state the user
  said it should not be in. 108 config keys.

## [0.0.10] — 2026-08-28

### Fixed

- **An OpenAPI document's `servers` base path was ignored when matching operations to
  endpoints.** OpenAPI 3 says the URL a client calls is `servers[].url` joined to the
  path, and an API mounted under a prefix may express that prefix in either place —
  in `servers.url` with paths relative to it (the idiomatic form), or inlined into
  every path with a bare host. Both are legal. Only the second one worked.

  The cost was invisible and total. Every operation in an idiomatic document landed
  under a path the application does not serve, matched no discovered endpoint, was
  dropped by the user's own `included_paths`, and was silently replaced by the same
  endpoint discovered from a recording — which carries no schema. So
  `require_schema_valid_response` was **inert for the whole API**, and every endpoint
  reported "no response schema is declared" as though that were a fact about the API
  rather than about our join. Confirmed against a real API described by four
  documents that split evenly across the two forms: 22 of 22 matched from the inlined
  pair, 0 of 22 from the idiomatic pair.

  Servers are resolved with the specification's precedence (operation, path item,
  root), server variables are substituted from their defaults, and servers that
  disagree on a base path warn rather than being chosen between silently.

- **A document and a route spelling one parameter differently were treated as two
  endpoints.** `/widgets/{widget_guid}` and `/widgets/{widget_id}` are one route, and
  keying the merge on the literal template put the document's schema on a row nothing
  measured while the measured row reported that no schema was declared for it. The
  merge is now keyed on segment structure; the application's own spelling is what gets
  requested, because a route is what the app serves and a document is a description
  that may have drifted.

- **"No document operation matched this endpoint" and "the matched operation declares
  no response schema" shared one sentence.** Two different facts, and only the second
  is about the user's API. Sharing a sentence is how the join defect above was
  reported for a whole API as a property of that API, pointing readers at documents
  that declared a schema for 50 of their 61 operations.

### Added

- **A 5xx that issued zero queries is named as one.** A request that issued no
  queries never reached the data layer, so no factory, trait, `param:` or scale factor
  can change its outcome. The number that proves it has been printed in the cell table
  since the first run — and an integration still spent four rounds recommending a
  factory fix for fifteen endpoints whose own rows read zero queries, because nothing
  in the report ever objected to a remedy its own data ruled out. This is the cheapest
  kind of check the tool can make: it uses a number already measured, and it rules out
  a whole class of wrong remedy.

- **The exception behind a rendered 500, and whether *we* caused it.** Rails rescues
  most exceptions and renders an error page, so a 500 arrives as an ordinary status
  with a large HTML body and nothing saying what raised. Under `:in_process` we are in
  the same process and already have it: the class and the first application backtrace
  frame are reported. Never the message — that routinely carries record ids, tokens
  and parameter values.

  And the half only the tool can see: when the failure was caused by our own
  `block_outbound_http` containment, it says so and names the host that was refused.
  A containment false positive is indistinguishable from a broken endpoint from
  outside, because the block is ours. One integration attributed fourteen such
  endpoints to their factories for three rounds.

- **Per-mount authentication.** `auth_overrides` gives a mounted second API — an admin
  surface, a partner surface, a callback surface — its own credential, strategy and
  header name, matched by path with the first match winning. With one `auth_strategy`
  that mount was unauthenticated on every request, which surfaces as a block of
  endpoints failing identically for a reason the report attributes to the application.
  `auth_header_name` also makes the `:header` strategy's header configurable; it was
  hardcoded to `X-Api-Key`, one convention among many. 105 config keys.

- **Each endpoint says which source discovered it.** The run line counts operations
  per source and never said which source produced a given endpoint, so a reader
  inferring provenance from it can be wrong about every endpoint at once — and was,
  publicly, for a whole round. The line now separates what each source **parsed** from
  what it **contributed** to the endpoints actually exercised, which are different
  numbers and only the second is what a reader means.

- **The query that returned no rows, with its filter columns.** "The seeded records
  did not match this endpoint's scope" is true and leaves the reader to find the scope
  themselves. Rails carries the row count on every query notification and nothing read
  it; an endpoint that 404s or comes back empty now names the table and columns that
  excluded the data, which is what points at the missing factory trait.

- **A finding says what was actually sent, values included.** Provenance answered "is
  this 404 ours or theirs" and not "what did you ask it" — and the second decides what
  a finding *means*: an endpoint taking a `view` parameter can issue 3 queries at its
  default and 147 at another value. A repeat count with no mention of the value is a
  property of one parameterisation reported as a property of the endpoint. It cost one
  integration a full code trace to establish that our number was right.

- **Repeat counts separate what executed from what the query cache served.** A request
  asking for the same row 21 times may execute 12 and have 9 served from the
  request-level cache; a reader reproducing it in a console — no request wrapper, so no
  cache — sees 21 and concludes the tool is wrong. Both numbers are now stated. The run
  also warns when `disable_query_cache_during_run` is true and cached queries arrive
  anyway, which means Rails' own QueryCache middleware re-enabled it per request after
  our disable.

- **The noise floor prints its value and where it came from.** The prose said "this
  machine's measured noise floor" and printed no number anywhere, so a reader could not
  tell what bar was applied, whether it was measured or stored, or whether the
  measuring path ran at all — and was left inferring it from which deltas survived.

## [0.0.9] — 2026-08-28

### Fixed

- **`record` read `integration_spec_paths` before booting the application, so it was
  always empty.** The setting lives in `config/initializers/loadwright.rb`, which
  only exists once the app has booted — and the command resolved its spec list
  first. Every app that configured it the way the generated initializer says to got
  a refusal, naming the very setting the command had just failed to read. Someone
  following that message goes and checks a setting that was correct all along.

  `run` never had this, because it reads config after booting; that is why the same
  setting drove discovery correctly in the very next command. `record` now boots
  first. `--specs` still wins when passed, and blank entries no longer count as
  paths.

- **`compare` could only use a measured noise floor if a baseline happened to store
  one.** `baseline set` measures this machine's run-to-run spread from a second run
  on the same commit; `compare` read it from the stored baseline and from nowhere
  else. So a plain `compare <a> <b>` fell back to `regression_threshold_pct` alone —
  the threshold this project's own documentation calls a guess — and reported a
  laptop being busier in the afternoon as a regression on ~30 unrelated endpoints.

  It now measures one from history when no baseline stores it, and says so. **Never
  from the two runs under comparison**, which would be circular: the floor is the
  maximum spread across the pair it is measured from, so using it on that same pair
  defines every one of that pair's own deltas to be noise.

### Added

- **A regression report says when its evidence has the shape of a busier machine.**
  Every regression being latency, all in the same direction, spread across unrelated
  endpoints including ones that touch no database, with no query-count movement
  anywhere, is the laptop rather than the code — and the tool's own rule already says
  query deltas are the primary signal because they are near-deterministic.

  The verdict stays **REGRESSED** and the exit code is unchanged. A comparison that
  quietly decided a regression was noise would be the same class of error one
  direction over; what was missing is not a softer word but the sentence saying what
  the shape looks like. The evidence was all present and nothing assembled it.

- **Every endpoint says whether its response was checked against a declared schema.**
  `require_schema_valid_response` defaults to true and the report contained the word
  "schema" nowhere — not in the checked half of the coverage line, not in the
  not-checked half. A reader could not tell a validated response from one that was
  never validated because the operation declares no schema, which is precisely the
  distinction the setting exists to make.

  It renders as its own line, and on the one line a clean endpoint gets. It is
  **not** a `Coverage` class: schema validity belongs to the validity gate, a
  violation makes the endpoint `inconclusive` rather than producing a finding, and
  adding it to the coverage map would mark every endpoint without a declared schema
  uncovered — the `inconclusive` flooding the three-state model exists to prevent.

  Only an OpenAPI document supplies a schema; a recording cannot. An app discovering
  purely from recordings now sees that stated on every endpoint.

- **An N+1 repeat count prints its denominator.** "the same query ran 12 times in a
  single request (of 73 queries in that request, seed_scale scale=10)". The invariant
  — a repeat cannot exceed its own request's query count — has been specced since
  0.0.5, but for five releases the two numbers were printed in different parts of the
  report, and a finding reading "ran 12 times" sat above a cell table reporting 8
  queries per request without anyone, us included, seeing the contradiction. Nothing
  here enforces the invariant; putting both numbers in one sentence is what lets a
  reader enforce it. Sub-threshold observations carry it too.

- **`--accept-long-run`.** The >10-minute confirmation already proceeds on a non-TTY
  — it is a courtesy about someone's afternoon, not a safety decision about
  irreversible harm — but reaching that path meant detaching stdin, reshaping the
  process to answer one question and changing how every other prompt behaves as a
  side effect. `record` got `--accept-database-writes` in 0.0.5; this is the
  equivalent for the cost prompt.

## [0.0.8] — 2026-08-27

### Fixed

- **A repeated query below the reporting threshold is reported, not dropped.** An
  endpoint issuing the same query twice per request appeared in the clean list
  looking identical to one that issued it once — the detector had seen something
  and said nothing.

  That silence is how three endpoints moved from a high-confidence
  `n_plus_one_pattern_match` to "healthy" across four rounds with nothing anywhere
  to explain the transition. The counts themselves were being *corrected* — before
  0.0.5 a repeat count was a sum across cells, so a two-cell run reporting "ran 4
  times" was a true per-request repeat of 2, under the threshold of 3 — but no
  report said so, in either direction. Endpoints fell under the threshold and
  simply stopped being mentioned.

  Sub-threshold repeats now render on the endpoint as an observation: not a
  finding, not invisible. The threshold is `n_plus_one_duplicate_threshold`
  (default 3, floor 2), so lowering it to 2 turns them into findings.
- **An endpoint declined by policy is counted apart from one that could not be
  measured.** A mutating endpoint held behind `allow_mutating_requests = false`
  shared the reason `:no_example_available` with an endpoint that genuinely had
  nothing to send. Two situations, different fixes, different owners, one number.

  In one real run **45 of 73 inconclusive endpoints were policy declines**, so the
  headline said "73 could not be validly measured" when 45 of them were never
  attempted and are one config switch away, and the 28 real gaps were buried
  inside it. Policy declines now carry `:mutating_not_allowed`, the summary
  reports `not_measurable` and `declined` separately, and the state stays
  `inconclusive` — three states remain load-bearing and this is not a fourth.

- **Two runs from different versions of Loadwright are not comparable.** The
  comparability gate covered configuration and the app's observed page size, and
  left out the tool doing the measuring.

  `Comparator#resolved_for` already refuses to call a finding fixed when the
  endpoint stopped being measurable — it watches the endpoint's state, and missed
  the other door entirely: **the detector changing underneath two runs.** Between
  0.0.4 and 0.0.5 the pattern-match repeat count went from a sum across cells to
  the per-request figure it had always claimed to be. An endpoint reporting "the
  same query ran 4 times" under the old counting had a true per-request repeat of
  2 — below the reporting threshold — so it correctly stopped being a finding.
  Compare those two runs and the answer comes back `resolved:
  n_plus_one_pattern_match`: your fix worked, on an application nobody had
  touched.

  A **hard** divergence, not a caveat. Thresholds move, detectors get added, a
  measurement's meaning changes, and the tool cannot know which of its own
  releases were semantically neutral. Failing closed costs one re-run of the
  baseline on the current version; failing open costs somebody a day chasing a fix
  they already made — or believing in one they never made.

  The refusal says so in its own words rather than the generic "re-run under
  matching configuration", which is unhelpful when the dimension that moved is the
  tool: there is no configuration to match, and the fix is to re-measure the
  baseline with the version now installed. A record written before the version was
  persisted carries none, and absence is not treated as a difference.

## [0.0.7] — 2026-08-27

Polish, from a fifth round of outside integration that found nothing Critical or
High — a first for this project. Both items came from the same run: the first
**collection-shaped** endpoint the tool has ever measured.

### Fixed

- **A page size the sweep chose is the sweep's doing, not the endpoint's.** The
  first collection endpoint ever measured answered 200 at its own default and at
  page size 25, and 400 at page sizes 5 and 100 — same endpoint, same resolved id,
  a different verdict per cell. It accepts a set of page sizes and the sweep asked
  for values outside it. Reporting that as an ordinary error status sends a reader
  to look at their app for something the tool did. It now has its own reason,
  `page_size_rejected`, which names the values that worked, says to set
  `page_size_sweep` to values the endpoint accepts, and says what was lost — the
  N+1-behind-pagination check could not run on the rejected pages, which is the
  whole purpose of that sweep.

  Still `inconclusive`. Loosening the validity gate for a partly-successful
  endpoint is exactly how a 404 ended up in the healthy list in 0.0.4; what changes
  is the reason and the advice, not the verdict.

### Changed

- **Endpoint headers carry the status counts** when the cells disagree — `(4 × 200,
  2 × 400)` next to the verdict. A single `inconclusive` above four successful
  cells made a reader open the cell table to find out what actually happened.
  Omitted entirely when every request agreed.

### Upgrading

- **If you script `loadwright record`** — from CI, a Rakefile, a git hook — the
  acknowledgement added in 0.0.5 will refuse an unattended run the first time it
  executes after upgrading, where your `database.yml` declares a test database that
  `record` will not reach. That is the correct failure: it protects the database
  your suite is about to write to, and a prompt that cannot be shown counts as
  unanswered rather than as yes. Add `--accept-database-writes` to the invocation,
  or set `config.confirm_recording_database = false` if your suite is
  transactional. Where no distinct test database is declared, nothing is asked.
  Documented in the README under "Which database your specs will write to".

## [0.0.6] — 2026-08-27

One fix, from the same round-4 report as 0.0.5 and missed on the first pass.

### Fixed

- **A cluster of broken endpoints no longer aborts a run that also covers healthy
  ones.** Error-concentration quarantine asked "does ONE endpoint own 80% of the
  errors". When several endpoints are each failing on nearly every request, none
  of them does — so nothing was a candidate and the global breaker aborted the run
  around them.

  Observed for real: a user widened `included_paths` to reach a surface the
  previous release had just recovered. The run resolved 46 exercisable endpoints,
  then tripped at 38% — and **every one of those failures was on the old surface**,
  from a handful of endpoints already known to be broken. The run died before
  reaching the endpoints the widening was for. Adding coverage removed coverage,
  and nothing in the output said the new surface was innocent.

  Quarantine now also fires on an endpoint's **own** failure rate, which is what
  the breaker's "this endpoint is broken" half was always supposed to mean. The
  global abort is left for failure genuinely *spread* across the surface — a wrong
  token, an app that is down — with a guard so that quarantining can never work its
  way through most of the matrix one endpoint at a time.

  The spread check counts the endpoints the run **plans** to exercise, not the ones
  it has reached. Counting what has been seen is what made the old behaviour
  order-dependent: a cluster of broken endpoints at the front of the matrix looked
  like "everything is broken" before a single healthy one had been measured.

### Changed

- **The abort message names the endpoints most of the failures came from**, and the
  report lists what was quarantined with its failure count. "31 of 81 failed" gives
  a reader no way to tell whether the failures were spread across their API or came
  from three endpoints they already knew about.

## [0.0.5] — 2026-08-27

Five fixes from a fourth round of outside integration. One of them is the most
serious defect this project has shipped.

### Fixed

- **A 4xx or 5xx is an error path, however it was expected.** An endpoint that
  answered `404` to every one of its 171 requests was reported **healthy, with
  coverage complete**, while a sibling endpoint with byte-identical cell data was
  correctly `inconclusive`. That is the confidently-wrong all-clear this entire
  tool argues against, produced by the tool, inconsistently, inside a single run.

  The validity gate consulted `expected_statuses` for any non-2xx, justified by a
  comment about honouring a declared redirect. That list holds neither
  declarations nor successes. From a **recording** it is every status the specs
  were observed producing — and a suite makes requests it expects to fail, so a
  spec asserting a rejection against a bogus id taught us that 404 was expected
  here. From an **OpenAPI document** it is every declared response key, and every
  document declares its 401, 404 and 422 — so any app discovering from a working
  document had the same bug with a far wider blast radius, unhit only because the
  integration that found this has OpenAPI discovery disabled.

  A 3xx still passes when a source saw one, which was the original and correct
  intent. The gate also now names the likely cause, because "a spec was asserting
  a rejection" is a different sentence from "your endpoint is broken".
  **Mutation-audited**, since a green suite did not protect this.
- **The fixed/scaling classifier can reach the axis it was given.** 0.0.4 added a
  seeded-scale fallback for APIs with no returned-record count to read. It never
  fired once: the observations handed to the classifier were the **page-size**
  cells whenever that sweep ran, and those all share one seeded scale by
  construction. So it abstained while the report printed identical query counts
  across a hundredfold change in seeded rows a few lines below. The slope detector
  still sees one sweep at a time — that is what holding an axis fixed is for — and
  the classifier now sees every cell, because either axis answers its question.
- **`record` asks before running a suite against a database that is not the
  declared test one.** 0.0.4's warning was right for a transactional suite and too
  weak for the case that is both detectable and dangerous. The costs are wildly
  asymmetric — a transactional suite that proceeds loses nothing, a truncating one
  empties a developer's database irreversibly — so the friction goes there and
  nowhere else. An acknowledgement, not a refusal: `--accept-database-writes`
  answers it non-interactively, `confirm_recording_database` turns it off, and a
  prompt that cannot be shown counts as unanswered rather than as yes.
- **An empty capture names what survived.** "Nothing was written" was true and
  still left someone who had been bitten once going to check the file.

### Added

- **Every endpoint reports the request that was actually sent**, and where each
  value came from: from a seeded record, replayed from your specs, replayed and
  unresolved, or set by the page-size sweep. Two separate failures traced back to
  a report that never said this — a 404 nobody could attribute to us or to the
  app, and a confirmed 73-query finding that came back **healthy** in the next run
  because a changed recording stopped sending the parameter that selects its
  expensive representation. A confirmed defect un-found itself and neither report
  said the two runs had asked different questions.
- **`History::Comparator` refuses to attribute a change across a changed
  question.** A query count is never compared without its record count; it is not
  comparable across two runs that sent different parameters either. A changed
  parameter set strips the verdict exactly as a changed denominator does, and the
  note names which parameter moved. A baseline written before request shapes were
  persisted carries none, and absence is not treated as a difference.
- **The replayed-identifier note covers any unsuccessful status**, not only 404.
  A placeholder produces a 400 or a 422 just as easily.

### Note

Round 4's report proposed widening identifier-shape promotion to recover
templates carrying a literal segment. The tester withdrew that themselves on
inspection, and we agree: the shapes involved are indistinguishable from
legitimate route components, and promoting "segments that vary between
recordings" was built once and silently merged sibling endpoints. The id-shape
rule stays as it is.

## [0.0.4] — 2026-08-27

Six fixes from a third round of outside integration, and one correction to the
0.0.3 changelog below.

The shape of this round differs from the last two. Round 3's issues were "the fix
landed but the last mile did not". These are the opposite: **the fixes worked,
and the tool's own improvements exposed the next layer.** Naming the unmapped
recordings revealed why they were unmapped. Taking our own advice to raise
`scale_factors` revealed that N+1 counts scaled with configuration. Replaying
recorded parameters revealed an endpoint that had been "healthy" for three rounds
only because nobody had sent it the parameter that selects the expensive answer.

### Fixed

- **N+1 repeat counts are per-request again.** A finding said "the same query ran
  N times in a single request" where N was a **sum across every cell**. The
  per-cell code takes the worst single request and carries a comment explaining
  why; the merge one level up concatenated. The number was therefore a property
  of the reader's configuration: cells going 2 → 6 between two runs of an
  unchanged application tripled every N+1 count exactly. Taking our own advice to
  raise `scale_factors` punished the reader with severities three times worse for
  no change in behaviour, corrupted run-over-run comparison, and made a fixed
  repeat look like one that scales — arguing against the classifier shipped in
  the same release. The invariant that catches it (no repeat count may exceed the
  endpoint's queries per request) is now a spec.
- **A doubled leading slash no longer costs the recording.** `//api/v1/thing` is
  a protocol-relative URL, and `Rack::MockRequest.env_for` parses it as one — the
  first segment becomes the authority and vanishes from `PATH_INFO`. The router
  was then asked about a path missing its first segment, answered nil, and the
  recording was dropped and counted. Twenty-two recordings lost in one real run
  had this shape, all from a mounted Rack app whose mount point and sub-path each
  contributed a slash. The router recognises both forms when asked directly;
  nothing was wrong but our own request construction.
- **An empty capture no longer overwrites a good recording.** It replaced the
  file and then printed that nothing had been written to that path — so a reader
  had no reason to check, and the next command refused with "0 endpoints" several
  steps removed from the cause. Recording is the slowest step in the workflow.
  Refusing the write is also what makes the existing message true.
- **An identifier in a query string is treated as an identifier.** Path
  parameters get a four-source resolution chain in which a recorded id ranks
  last, because a spec's ids do not exist in the database being measured. The
  same id in a query string was replayed as fact, so a spec placeholder went out
  verbatim, matched nothing, and the endpoint answered 404 as though it were
  broken. Identifier-shaped query parameters now resolve from a seeded row first;
  ordinary filters are untouched. Where nothing can resolve one, the recorded
  value still goes and the endpoint is marked, so a 404 says the request carried
  an identifier we could not resolve rather than presenting it as the app's
  answer.
- **When the fixed/scaling classifier abstains, the advice abstains too.** On an
  API of single-record detail endpoints there is no returned-record count to
  read, so the classifier correctly declined on every finding — and every one
  then carried confident preload advice, which was the wrong fix for all of them.
  The unclassified suggestion now names both branches and says what to vary to
  settle it. There is also one more axis to ask first: a query count identical at
  seed scale 1 and seed scale 100 did not move while the data underneath it moved
  a hundredfold. That gets its own value, `fixed_by_seed_scale`, rather than
  being folded into `fixed` — a paginated collection is flat against seeded scale
  by construction, and the suggestion names that assumption instead of burying it.

### Added

- **`record` says which database it is about to run your test suite against.**
  It boots the app and then runs RSpec in the same process — it has to, since the
  recorder is a module prepended to a class there. The consequence went unsaid:
  the `ENV["RAILS_ENV"] ||= "test"` in a conventional `rails_helper` is a no-op
  by then, so the suite runs against whatever database the CLI booted into,
  normally development. A fully transactional suite rolls everything back and
  nothing leaks — luck rather than containment. One that truncates, commits, or
  uses `before(:all)` writes to development data, and one that truncates between
  examples would empty it. Not a refusal: running those specs is what was asked
  for. But it is the user's call only if they know they are making it.

### Correction to 0.0.3

The 0.0.3 entry below says the recording's environment tag "was wrong". **That
was based on a premise that turned out to be false, and it is withdrawn here
rather than quietly edited.** The claim was that `record` runs specs against the
test database; it does not, for the reason above. The recording named the
development database because the specs ran against the development database, in
0.0.2 as well as 0.0.3.

The 0.0.3 change is still the right design — sampling at capture time and
recording the database name rather than the environment name answers the question
directly instead of by proxy. It was not, however, fixing a bug that existed.

The real problem in that area is different and is not solved by comparing names:
recorded ids from a transactional suite are **ephemeral**, rolled back at the end
of each example, so they exist in no database afterwards. Only checking whether a
recorded value resolves to a row can catch that. It remains unfixed and is
masked in practice by seeded values outranking recorded ones.

## [0.0.3] — 2026-08-27

Seven fixes from a second round of outside integration. Two of them are the same
species as the round-2 batch and worth naming as such: **the fix landed but the
last mile did not.** Environment tagging was added and tagged the wrong value;
orphan adoption existed and ran on one code path only. Neither was a design
problem — both were a step short of complete, and both reported all clear while
incomplete, which is the failure mode this tool exists to argue against.

### Fixed

- **A recording now records which DATABASE it was made against**, sampled inside
  the spec that issued the request. 0.0.2 added the environment tag and then
  sampled it in the CLI process — which boots before the specs run and does not
  follow them to the test database. A recording made entirely of test ids was
  tagged `development`, the guard compared `development` to `development`,
  passed, and dropped nothing. The environment name was only ever a proxy for
  "did these ids come from the database this run measures"; the database name
  answers it directly, and the environment comparison remains the fallback for a
  recording that carries no database. A guard that reports all clear without
  working is worse than no guard.
- **Cleanup no longer spares a row because another table has one with that
  number.** The associated-row sweep skipped an exclusion list built by
  flattening every resource's tracked ids into one array and applying it to a
  single table. Ids are per-table sequences, so the collisions were spared: rows
  created by the run, above that table's own watermark, left behind because some
  other table had a row with that number — while the log reported the count of
  what cleanup had decided to delete. Cleanup now also asks the database
  afterwards, and says so if anything created during the run is still there.
  Silent litter accumulates run over run and is invisible until somebody counts.
- **Fix suggestions name an association you can actually type.** The name came
  from hand-rolled suffix stripping, which turned a table ending in `ses` into a
  non-word — `includes(:<nonword>)` raises `AssociationNotFoundError` if you
  follow it. It now goes through ActiveSupport's inflector, which also means a
  host that registered an irregular inflection gets its own answer.
- **`includes` is no longer suggested for a repeat that does not scale.** A
  request that finds the same already-loaded row four times wears the same
  signature as a per-record N+1 inside one request — but not across cells: a
  per-record N+1 issues more queries as more records come back, and a fixed
  multiplier does not. Where that flatness is measured, the finding says so
  (`evidence.scaling: fixed`) and the advice becomes "pass the loaded object
  down, or memoize" instead of "preload". Where it was not measured, the advice
  is unchanged — flatness that was never measured is not flatness.
- **The request is rebuilt from what the recording actually held.** Discovery
  captured the query parameters and headers of a passing spec's request and the
  run sent neither, so an endpoint needing an `Accept` header answered 406 and
  one with a required query parameter answered 400 — coverage lost to the
  reconstruction rather than to anything about the app. Governed by
  `replay_recorded_headers` (default `Accept`, `Content-Type`) and
  `replay_recorded_query_params` (default `true`). Headers are replayed by name,
  never wholesale; the identity's auth header wins over a recorded one, and the
  page-size sweep's parameter wins over a recorded page size.
- **Unmapped recordings are named, not just counted.** A recorded request the
  router does not recognise is dropped and counted honestly — but those endpoints
  then appeared nowhere else, making them the one "could not measure" case with
  no row of its own. The samples were already collected at record time and thrown
  away at write time; they now travel with the recording.
- **One situation, one sentence.** Two endpoints returning 500 on every request
  were described two different ways depending on which mechanism noticed first —
  the validity gate, or error-concentration quarantine. Both now lead with the
  same sentence and the quarantine detail names the status it saw. The reason
  symbols stay distinct in the machine-readable output.

### Changed

- **The dry run says when the page-size sweep will not be able to run.** The
  sweep correctly refuses when the largest scale factor cannot fill the largest
  page. What was easy to underweight is the consequence: that sweep is one of two
  N+1 detectors and is specifically the one that catches an N+1 hiding behind
  pagination, so a paginated endpoint in the healthy list has had half the check
  applied. It is reachable from the shipped defaults, and it belongs in the dry
  run rather than in a report you read afterwards.
- **The generated initializer stops assigning two lists it is only documenting.**
  `production_hostname_patterns` and `page_size_parameters` now ship commented
  out with their current defaults named, the way `redact_header_patterns`
  already does. Assigning a copy of today's list freezes it: a release that
  learns to recognise a production host yours matches would never reach an app
  generated before it, and the safety list is the worst one in the file to
  freeze. Existing initializers are worth auditing for the same pattern.

### Note on `v0.0.2`

Bundler resolves the annotated tag `v0.0.2` to `d4f81e4`, the tag OBJECT. The
commit it points at is `1ac8a89` (`git rev-parse v0.0.2^{}`). The tag has not
moved; the two SHAs are the two halves of one annotated tag.

## [0.0.2] — 2026-08-27

### Added

- **Cleanup now covers rows your app created.** Previously it tracked only what the
  factories wrote, so a run against a `POST` endpoint left one record per request
  behind — and so did a `GET` that writes an audit row or touches a `last_seen_at`.
  The table is learned from the INSERT fingerprints already being collected, so it
  works in both execution modes with no extra instrumentation, and it reuses the
  same pre-seed watermark: still strictly id-bounded, still never a `TRUNCATE`,
  still incapable of reaching a row that existed before the run.
  Governed by `cleanup_request_created_rows` (default `true`).
- **`auth_login`** — name the login request your own clients make, and where the
  token is in the answer, instead of writing the code that mints one inside your
  initializer. Issued once per credential before the run, through the same
  transport; those requests are setup and are never measured or reported as
  endpoints. Supports a JSON path or a response header (for session auth), and a
  list of credentials, which is how you get multi-identity traffic. A failed login
  stops the run with the status, and never echoes the credential back.
- **Fix suggestions on N+1 findings.** The report already named the repeated query
  and the file and line; it now also names the shape of the likely fix. Notably it
  does *not* say "add `includes`" for a repeated `COUNT`, where that advice is
  wrong — a preloaded association is still counted with a query unless the code
  stops counting, so the fix is a counter cache or `.size` on a loaded collection.
  Suggestions are advisory: they never change an outcome state or the exit code,
  and a query shape that is not recognised gets no suggestion rather than a
  guessed one.
- **GraphQL operations are discovered and measured.** Every GraphQL operation is a
  `POST` to one path, so path-based discovery reported an entire API as one row.
  Operations are now the unit of work, sourced from `.graphql` documents or an
  inline list — never generated from the schema, because a generated query measures
  traffic the app never receives. Two consequences worth naming: a `query` counts as
  a **read** despite travelling by `POST`, so measuring one does not require
  `allow_mutating_requests`; and a failed GraphQL query answers **HTTP 200**, so the
  validity gate now recognises the `errors` envelope and reports those endpoints
  `inconclusive` instead of fast and healthy.
- **GraphQL pagination is swept.** A paginated operation's query count is flat
  against seeded scale, so only varying the page size reveals an N+1 behind it —
  and in GraphQL the page size is a variable inside the document rather than a
  query parameter. Loadwright varies a variable named in
  `graphql_page_size_variables` across `page_size_sweep`, and counts returned
  records from a plain list field or from `edges`/`nodes` on a Relay connection.
  An operation that hardcodes `first: 10` is reported as unsweepable, with the
  parameterisation to make it sweepable, rather than measured three times at the
  same size and reported flat.
- **Per-resolver attribution for GraphQL.** `trace_with
  Loadwright::Instrumentation::GraphqlTracer` on your schema makes findings name
  the resolver — "resolved by `Author.postCount`" — rather than only the operation.
  The tracer no-ops outside a run, so it is safe to leave installed, and `graphql`
  remains a non-dependency: it is a plain module your schema opts into.

- **`loadwright init`** — writes `config/initializers/loadwright.rb` with the settings
  most apps actually need, 77 lines instead of 497. `rails generate
  loadwright:install --minimal` does the same. Everything it omits keeps its default,
  which is the point: assigning a key freezes it at today's value.

### Fixed

- **Path parameters resolved to the primary key, and an explicit override could not
  override it.** An API routing on a public identifier — guid, slug, uuid, which is
  the norm for anything that declines to leak sequential ids — got its primary key
  substituted and 404'd every request. `path_param_overrides` sat *third* in the
  resolution order, behind two inferences, so the documented fix could not take
  effect. An override is now **first**; `factory_map` accepts `param:` to name the
  column the API routes on; and parameter names ending `_guid`, `_uuid`, `_slug`,
  `_code`, `_key`, `_token`, `_number` and `_ref` now map back to their resource
  rather than only `_id`.
- **An endpoint could request its own raw template.** A declared-but-empty parameter
  list won over the template, so a path visibly containing `{id}` claimed to have no
  parameters and went out as a URL — `URI::InvalidURIError`, once per request. The
  template is now authoritative, and a resolved path still containing `{` is reported
  unresolved rather than requested.
- **Recorded ids came from the wrong database.** `record` runs specs against `test`;
  `run` measures `development`. Recordings now carry the environment they were made
  in, and values from a different one are dropped with a warning while the parameter
  stays declared.
- **The generated initializer replaced the redaction defaults.** Assigning
  `redact_header_patterns` froze it, so the broadened credential list did not reach
  anyone who had generated a file before it shipped. That key is now commented out,
  with `redact_additional_patterns` shown as the way to add.
- **`--specs` kept only the last value.** It now accumulates.
- **Reconstructed mounted paths carried a doubled slash**, and a query string could
  stop an id-shaped segment being recognised — leaving one endpoint per record.
- **`loadwright record` broke any rswag-based suite.** It called `RSpec.reset`,
  which replaces the `Configuration` singleton and discards every setting a gem
  registered at *require* time. Those gems are already loaded by then — Loadwright
  boots the app first — so their `require` in `spec_helper` is a no-op and they
  never re-register. rswag's `openapi_root` vanished and the host's own
  `spec_helper` died with `NoMethodError` before a single example ran. It now calls
  `RSpec.world.reset`, which clears example groups without touching configuration.
  A suite that errors before recording also now says so, instead of reporting "the
  specs ran but made no recordable requests" — which sent people to rewrite tests
  that were fine.
- **Rack-mounted APIs collapsed to their mount point.** Rails reports
  `mount MyApi => "/internal/api"` as one route, so every endpoint behind it recorded
  the same template, merged into a single endpoint, and got requested at the bare
  mount point — a 404. Templates are now recovered from the recorded paths by
  promoting id-shaped segments, so `/internal/api/widgets/{widget_id}/customer` comes
  back with its id intact. Affects Grape, Sinatra, Roda and any mounted Rack app.
- **A custom auth header was written to the recording in plaintext.**
  `redact_header_patterns` matched `Authorization` but not `X-Account-Key`, so an app
  using a custom auth header had its live credential written to disk while `Cookie`
  beside it was redacted. The defaults are now broad — `auth`, `token`, `secret`,
  `credential`, `session`, `signature` — because a custom auth header is the norm
  and the cost of redacting a harmless one is nothing.
- **One broken endpoint aborted the whole run.** The circuit breaker is global, so
  a single endpoint returning 500 on every request tripped it and abandoned every
  endpoint the sweep had not yet reached. When errors are concentrated in one
  endpoint (≥80%), that endpoint is now quarantined as `inconclusive` and the run
  continues. Errors spread *across* endpoints still abort — that is the case the
  breaker exists for.
- **An unparseable OpenAPI document had no triage path.** The refusal is correct and
  unchanged, but 20 truncated errors on a terminal is not something a team can act
  on. The full list is now written to `openapi-errors.json`, the message says how
  many paths are affected out of how many ("52 errors across 31 of 44 paths"), and
  it names the two discovery sources that need no document at all.
- **`record` now warns about pending migrations** before running your specs, instead
  of letting every spec file fail with the same stack trace.
- **A foreign exception's message is bounded** where it crosses into our output.
  Ruby builds a `NoMethodError`'s message from the receiver's inspect, so one raised
  against a large object can bury the four words that matter.
- **The two execution modes sent different content types for the same request.**
  `:http` JSON-encoded a structured body; `:in_process` form-encoded it, turning
  every value into a string. Invisible for most REST params, which Rails coerces
  anyway — and fatal for GraphQL, where `Int!` rejects `"3"`.
- **Authentication was never sent.** `IdentityPool#resolve!` was called from nowhere
  in `lib/`, so a configured `auth_token_provider` produced a pool whose tokens were
  never resolved: every request went out unauthenticated, every endpoint returned
  401/403, and the report told the user their token was probably misconfigured. It
  was not — the tool never sent it. This is the failure `AGENTS.md` documents as the
  most common on a first run, and it was self-inflicted. The pool is now resolved
  once, before any request is issued, and `examples/sample_app` has an endpoint that
  actually checks a token so no fixture can hide it again.
- `auth_strategy` documented `:none` and `:custom`, neither of which exists, and
  omitted `:header` (`X-Api-Key`), which does. All three real strategies are now
  documented with the header each sends, and an invalid value is rejected at
  startup rather than mid-run.

## [0.0.1] — 2026-08-24

First public release. Pre-1.0: the CLI surface and config keys are stable enough
to document but not yet frozen.

### Added

**The tool itself**

- `loadwright run` — discovers a Rails API's endpoints, seeds data through the
  app's own FactoryBot factories at increasing scale, exercises every endpoint
  under a scale × concurrency matrix, and writes a report. `--dry-run` is the
  default and sends zero requests.
- `loadwright record --specs <path>` — runs the app's own request specs and
  records the requests they make, so discovery can resolve real path parameters
  instead of sending example IDs that 404.
- `loadwright runs list`, `baseline set`, `compare` — persisted run history and
  regression comparison against a designated baseline.
- `rails generate loadwright:install` — writes a fully documented initializer,
  adds `tmp/loadwright/` to `.gitignore`, and pre-fills discovery settings from
  what it finds on disk.

**Discovery** — OpenAPI/Swagger documents, recorded integration specs, and Rails
route introspection, merged on `(path template, verb)`. A named OpenAPI document
that is missing or only partly parseable fails loudly rather than silently
producing a partial endpoint list.

**Analysis** — N+1 detection by both repeated-query pattern and by slope against
*returned* record count (which is what catches the N+1 a paginated endpoint hides
from a seeded-scale measurement); missing pagination; over-fetch hints;
`EXPLAIN`-based index analysis on PostgreSQL, MySQL and SQLite; latency
percentiles; db/view/GC time breakdown; cold-vs-warm cache; a static
pool-vs-server-threads check.

**Reporting** — self-contained HTML (no external assets), Markdown and JSON,
all rendered from one structure. Every run states what it could and could not
measure, and why.

### Safety

- Refuses to run outside `development` and `test`. Running anywhere else requires
  four separate things: `allow_production`, an app-specific
  `confirmation_phrase`, `--i-understand-the-risk`, and that phrase typed
  interactively. A dry run is the default, and `--execute` is what overrides it.
- Remote HTTP targets bypass local environment detection entirely, so they are
  treated as production-adjacent regardless and asked to identify themselves.
  The target's answer is authoritative for *refusal* and never for *approval*.
- Cleanup deletes only the rows Loadwright created, tracked by primary key. It
  never truncates a table.
- Mail delivery, background jobs and outbound HTTP are suppressed by default. If
  containment cannot be enforced the run aborts rather than proceeding
  unprotected.
- Mutating verbs are skipped unless `allow_mutating_requests` is set.
- Database contention triggers a five-rung retreat — backoff, step down,
  quarantine, cool down, abort. Loadwright never terminates a database session.
- `SIGINT`/`SIGTERM` stop the run, tear down any booted server, delete seeded
  rows, and write a partial report marked as partial.
- Every run records the safety decision that permitted it, so a run's provenance
  is auditable after the fact.

### Requires

`webmock` in your `:development, :test` group. `block_outbound_http` is on by
default and webmock is what enforces it; without it `--execute` refuses rather
than proceeding unprotected. It is not a hard dependency, because it is a
testing library with opinions of its own and forcing a version on a host app
would be worse than asking. `--dry-run` works without it, and warns.

### Known limitations

Stated here rather than left to be discovered:

- **Memory and connection-pool pressure are not measured.** The trackers exist
  but nothing in a run collects from them, so no allocation figure or pool sample
  reaches a report. Every run says so explicitly instead of reporting a number.
  The static pool-vs-threads check *does* work and is a real finding, but it is a
  configuration comparison, not an observation of pressure.
- **Concurrency findings need `execution_mode = :http`.** In-process execution
  has no server thread pool; those signals are reported unavailable, never as
  zero.
- **An `:http` run against a server Loadwright did not boot** cannot be
  instrumented, so it reports honestly reduced capability rather than confident
  numbers it never measured.
- **GraphQL subscriptions are skipped.** They are not answered over a plain HTTP
  POST, so there is nothing to measure. Queries and mutations are fully supported.
- **Multiple databases and read replicas** are not modelled; pool tracking
  assumes a single pool.
- **Tested on Ruby 4.0 and Rails 8.1.** The gemspec floor of Ruby 3.1 / Rails 7.0
  reflects the APIs used, not a tested matrix.

[Unreleased]: https://github.com/Matarim/loadwright/compare/v0.0.8...HEAD
[0.0.8]: https://github.com/Matarim/loadwright/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/Matarim/loadwright/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/Matarim/loadwright/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/Matarim/loadwright/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/Matarim/loadwright/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/Matarim/loadwright/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/Matarim/loadwright/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/Matarim/loadwright/releases/tag/v0.0.1
