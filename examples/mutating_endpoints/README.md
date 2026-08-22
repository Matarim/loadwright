# Mutating endpoints

The `allow_mutating_requests` opt-in, and what it makes possible.

## Read this before copying it

Everywhere else in this example set, the worst outcome of a misconfiguration
is a bad measurement. **Here it is a side effect in the real world**, and the
environment gate does nothing about it.

Hitting `POST /orders` five hundred times can:

- send five hundred real emails
- enqueue five hundred real jobs
- fire five hundred webhooks at a partner's sandbox
- burn real third-party API quota

…from a laptop, in development, with every environment check passing. The
environment gate protects your *database*. It has nothing to say about the
rest.

That is why side-effect containment is a separate subsystem with its own
abort, and why it is on by default.

## The rule

**Do not turn a containment measure off to make a run proceed.** Turn one off
only when you have decided that the specific consequence is acceptable.

If containment cannot be enforced — no `webmock`, no ActionMailer —
Loadwright **aborts**:

```
refusing to run: side-effect containment is enabled but cannot be enforced.

  - outbound_http: webmock is not available. Any HTTP the app makes will be
    real, once per request.
```

Warn-and-continue would be the wrong default. You believe you are contained;
silently not being contained is the failure that mails five hundred real
customers from a dev box. An aborted run that annoys you is the better
outcome, and the message names every unenforceable measure at once rather
than only the first.

`abort_if_containment_unavailable = false` proceeds anyway, loudly, and the
report records that containment was not in effect. That is a deliberate
acceptance, not a workaround.

## Suppression is also a measurement

The `:test` adapters **record** instead of performing. That turns containment
into a signal you could not otherwise get:

```ruby
config.jobs_enqueued_warning_threshold = 10
```

A request that fans out into 200 background jobs is a finding in its own
right. It is measured as a **delta over the request**, not the accumulated
total — and it is reported `unavailable` rather than guessed when two
requests overlapped, because crediting one request with another's jobs is a
wrong attribution on a finding people act on.

## The confound you cannot configure away

Firing `POST /orders` 500 times means request 500 runs against a table
holding 499 more rows than request 1. **Latency drift there reflects data
growth, not concurrency.**

Loadwright discloses this rather than presenting the trend as a concurrency
finding. Keep `requests_per_endpoint_per_level` low so the confound stays
small.

## Cleanup, and its limit

Loadwright deletes the rows **it** created, tracked by id.

Rows **your endpoints** created are not Loadwright's to track, and it will
not guess. A `POST` that writes to three tables leaves rows behind. That is
your cleanup, not the tool's — and a tool that tried to infer it would
eventually delete something it should not have.
