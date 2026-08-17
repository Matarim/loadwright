# Production Safety Guard — Design Reference

> **Status: specification for software that does not exist yet.** Nothing
> described in this document has been built. Every statement here defines
> *intended* behavior, not current behavior — read it as a build order, not
> as documentation of a working system. When implementation diverges from
> this document, update the document in the same commit.


This is the most important subsystem in the gem. Build it first, test it
hardest, and treat any ambiguity here as a reason to stop and ask rather
than guess.

## Why a single `Rails.env.production?` check is not enough

- Environments get renamed (`staging`, `prod`, `production-eu`, `live`).
- `RAILS_ENV`/`RACK_ENV` can be unset or wrong in some deploy setups.
- A developer could run Loadwright against a *staging* box that has
  production-shaped data and production-shaped consequences (real customer
  emails, real third-party webhooks firing) even if `Rails.env` says
  something else entirely.

So detection has to be layered, and the default posture has to be
deny-by-default rather than block-known-bad-things.

## Layer 1 — Environment allowlist (default-deny)

```ruby
config.enabled_environments = [:development, :test]
```

If the running environment's name is not in this list, **Loadwright refuses
to run, full stop, before parsing config further.** This check happens
first, before discovery, before touching the database, before anything.

## Layer 1b — Remote targets in `:http` mode (the gate's biggest hole)

`config.http_target_url` lets `:http` mode point at an already-running
server instead of booting one. That quietly breaks the assumption every
other layer rests on: **Layers 1 and 2 inspect the *local* process's
environment, but the thing receiving the load is a different process,
possibly on a different machine, in a different environment entirely.**
A developer running from their laptop in `development` could aim a scale
sweep at a production URL and pass every check above.

So whenever `http_target_url` is set to anything that isn't loopback:

1. **Treat it as production-adjacent by default.** Run the full Layer 3
   opt-in flow (config flag + typed confirmation + `--i-understand-the-risk`
   + dry-run first), regardless of what the local `Rails.env` says.
2. **Run the hostname heuristics against the target URL's host**, not just
   the local hostname and `DATABASE_URL`.
3. **Ask the target what it is**, via the identity endpoint described
   below. Refuse outright if it reports an environment name outside
   `enabled_environments`.
4. **Refuse entirely if the target is unreachable or won't identify
   itself** while `allow_production` is false. An unidentified remote
   target is exactly the case to fail closed on.
5. **Record the resolved target host in the report metadata**, so a run's
   provenance names what actually received the traffic.

### Two endpoints, not one — and why

There is a circularity to resolve here. We need to ask the target what
environment it is *before* approving a run, but the collector endpoint
(`execution-modes.md`) mounts only *after* the guard approves. The endpoint
that would answer the question doesn't exist until the question is already
answered.

The fix is that these are two endpoints with different risk profiles, and
conflating them was an error:

**Identity endpoint** — mounted whenever the gem is loaded, which is
dev/test-only by Gemfile group. No secret required. Returns *only*:

```json
{ "env": "development", "loadwright_version": "0.1.0", "enabled_here": true }
```

No SQL, no stack traces, no bind values, no timing. It leaks essentially
nothing, so it does not need the guard's approval to exist. And note the
property that makes it safe: if the gem isn't loaded in production, the
endpoint isn't there. If someone *has* loaded it in production, an endpoint
answering `"production"` is exactly the signal we want.

**Collection endpoint** — unchanged. Fully guard-gated, localhost-bound,
per-run shared secret, unmounted after the run. See `execution-modes.md`.

### Trust is asymmetric

This is the rule that makes a self-report safe to act on at all. **A remote
target's self-report is authoritative for refusal and never for approval.**

| Target says | Consequence |
|---|---|
| An environment outside `enabled_environments` | **Hard refuse.** No override path. |
| `development` / an allowed environment | **Grants nothing.** Every other Layer 3 condition still applies in full. |
| Nothing — unreachable, or won't identify itself | **Refuse**, per the fail-closed rule above. |

A wrong or malicious answer can therefore only ever make Loadwright *more*
conservative. There is no answer a target can give that unlocks anything.

`config.allow_remote_http_target` (default `false`) gates this whole path
independently of `allow_production` — someone enabling production access
for a local staging box shouldn't silently also enable remote targeting.

## Layer 2 — Heuristic production detection (runs even inside the allowlist)

Even when the environment name is allowed, run a secondary heuristic check
and warn (or block, depending on config) if it smells like production
anyway:

- `config.production_hostname_patterns` — regexes checked against
  `Socket.gethostname` and the current `DATABASE_URL` host. Ship sane
  defaults (`/\.rds\.amazonaws\.com$/`, `/^prod-/`, `/\.internal$/`) but
  let the user extend the list — every infra setup names things
  differently.
- Presence of platform-specific "this is a real deployment" signals (e.g.
  `ENV["DYNO"]` on Heroku, `ENV["KUBERNETES_SERVICE_HOST"]`) — treat these
  as **warnings**, not hard blocks, since plenty of staging environments
  also run in these platforms. Surface them loudly either way.

## Layer 3 — Explicit production opt-in (for the rare legitimate case)

If someone genuinely needs to run Loadwright somewhere outside the default
allowlist (e.g. a production-data-shaped staging box), all of the
following must be true simultaneously — missing any one aborts the run:

1. `config.allow_production = true` set in the initializer (a config file
   change, not a runtime flag — so it can't be fat-fingered from the CLI).
2. An interactive confirmation prompt where the user must type the exact
   value of `config.confirmation_phrase` (default: the Rails application's
   module name, so it's specific to the app, not a generic "yes").

   **There is deliberately no generic fallback.** The whole point of the
   app-module-name default is that the phrase can't be guessed generically;
   a hardcoded string like `"I UNDERSTAND"` would defeat exactly that. So
   if the phrase cannot be resolved:

   - and the run is taking the production-adjacent path → **refuse**, and
     tell the operator to set `confirmation_phrase` explicitly. Never
     substitute a generic phrase.
   - and the run is an ordinary dev/test run → irrelevant. It is never
     consulted and produces no error.

   Same one-way ratchet as the identity endpoint above: an unresolvable
   phrase can only ever cost a production-path run, never weaken one.
3. A CLI flag, `--i-understand-the-risk`, that must be passed explicitly —
   this makes the risk visible in shell history and in any CI/script logs,
   even though this whole path should almost never be scripted.
4. If `config.production_hostname_patterns` matched anything in Layer 2,
   an *additional* second confirmation specifically calling out what
   matched and asking the user to confirm they still want to proceed.

## Layer 4 — Dry run before real execution

Even after clearing Layers 1–3, the first pass of any non-development run
defaults to `--dry-run`: it resolves the full endpoint list, the full scale
matrix, and prints exactly what *would* be requested (paths, verbs, request
counts, whether any are mutating) without sending a single real request.
Executing for real requires a separate, explicit `--execute` flag in the
same or a follow-up invocation.

## Mutating requests are opt-in, separately from the environment gate

Regardless of environment, `config.allow_mutating_requests` defaults to
`false`. With the default, only `GET`/`HEAD`/`OPTIONS` endpoints discovered
are exercised. Turning on `POST`/`PUT`/`PATCH`/`DELETE` traffic is a
separate, explicit config decision — because even in `development`, a
badly-scoped `DELETE` in a scaled load test can wipe out seed data a
developer cares about, or (if pointed at a shared dev database) someone
else's data.

## Side-effect containment (independent of environment)

The environment gate protects the *database*. It does nothing about the
other things an endpoint does when you call it 500 times. Even in
`development`, on a laptop, a load test against `POST /api/v1/orders` can
send hundreds of real emails, enqueue hundreds of real jobs, fire real
webhooks at a partner's sandbox, and burn real third-party API quota.

All three containment measures default to **on**:

- `config.suppress_mail_delivery` — force `ActionMailer` `delivery_method`
  to `:test` for the duration of the run, restoring the original value in
  an `ensure`.
- `config.suppress_background_jobs` — force the `ActiveJob` queue adapter
  to `:test`, so jobs are recorded and counted in the report rather than
  performed. (Job *enqueue* volume per request is itself a useful
  performance signal — a request enqueuing 200 jobs is a finding.)
- `config.block_outbound_http` — block outbound HTTP except to
  `config.outbound_http_allowlist`. Depends on webmock being available.

If any enabled containment measure can't actually be enforced — the gem
isn't present, the app uses a custom mailer that bypasses ActionMailer, a
job backend is invoked directly rather than through ActiveJob — then with
`config.abort_if_containment_unavailable` (default `true`) the run aborts
rather than proceeding unprotected. Warning-and-continuing is the wrong
default here: the user believes they're contained, and silently not being
contained is exactly the failure mode that sends 500 emails to real
customers from a dev box pointed at a shared staging mail relay.

Which containment measures were active goes in the report metadata.

## Circuit breaker

Independent of environment: if the observed error rate for a run crosses
`config.max_error_rate_before_abort` (default `0.20`), abort the remaining
matrix immediately rather than continuing to hammer an endpoint that's
clearly broken or misconfigured (wrong auth, missing route, etc.). Log the
abort reason prominently in the report.

## Auditability

Every decision this subsystem makes — which environment was detected,
which heuristics fired, whether production opt-in was used, whether the
circuit breaker tripped — gets written into the report's metadata section
(see `reporting.md`), not just printed to STDOUT and lost. A report should
be able to answer "was this run safe?" on its own, without needing the
terminal scrollback.

## Testing requirements for this subsystem specifically

- A spec that stubs each `enabled_environments`-excluded environment name
  and asserts the run aborts before any discovery/seeding/request code
  path is reached (use a spy or raise-on-call double so an accidental
  request would fail the spec loudly).
- A spec per heuristic in Layer 2 proving it fires on a matching
  hostname/ENV var and doesn't false-positive on a plausible dev/test
  value.
- A spec proving Layers 3's four conditions are genuinely all required —
  drop any one and assert the run still aborts.
- A spec proving `--dry-run` never results in an actual HTTP request being
  sent (assert on the HTTP client/adapter directly, not just on output
  text).
- A spec proving the circuit breaker aborts remaining work once the error
  rate threshold is crossed, using a stubbed endpoint that always 500s.
- Specs for the remote-target path: a non-loopback `http_target_url`
  triggers the full opt-in flow even when local `Rails.env` is
  `development`; a target self-reporting a disallowed environment is
  refused; an unreachable/unidentified target is refused rather than
  assumed safe.
- A spec proving asymmetric trust in both directions: a target reporting
  `development` still requires every Layer 3 condition (it grants nothing),
  and a target reporting `production` is refused with no override path.
- A spec proving the identity endpoint exposes only environment name,
  version, and the enabled flag — asserting on the response body, so a
  future change can't quietly widen it into the collection endpoint's
  payload.
- A spec proving an unresolvable `confirmation_phrase` refuses the
  production-adjacent path rather than falling back to a generic phrase,
  and does not raise on an ordinary dev/test run.
