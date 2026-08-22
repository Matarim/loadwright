# `:http` mode

A real server, real sockets, real thread contention.

## Who this is for

Someone asking a **capacity** question.

`:in_process` — the default — answers query-structure questions with zero
setup, and it is the right mode for most questions most of the time. It is
not a lesser mode. But it cannot answer "what happens at concurrency 20",
because there is no server thread pool to contend for: the harness *is* the
app.

## What this mode adds

| Signal | Why it needs `:http` |
|---|---|
| latency under concurrency | threads inside one process sharing a GVL measure nothing a user would experience |
| connection pool exhaustion | there is no pool contention when there is one caller |
| true client latency | includes the full middleware stack and the socket |
| clean memory attribution | the app has its own process, so the heap is its own |

In `:in_process` these are reported **unavailable, with the reason** — never
as zero. An absent finding is not a clean bill of health, and the report says
which it is.

## What it costs

- A real Puma boot per run, plus the health-poll wait for it.
- Correlation machinery. The harness cannot read the app's
  `ActiveSupport::Notifications` directly, so metrics come back over a
  loopback-bound, secret-guarded collection endpoint.

## The finding this mode exists for

```ruby
config.check_pool_vs_server_threads = true
```

More server threads than ActiveRecord pool connections means threads queue
for a connection under load, and latency collapses in a way that looks
exactly like a slow database and is not. The queries are fine; the requests
are waiting for permission to make one.

Loadwright reports this **even when no contention was observed** during the
run. It is a latent problem, a run at concurrency 5 will not provoke it, and
stating it costs nothing. The report distinguishes "we saw it happen" from
"we did not, which does not clear it".

The comparison is per *process*: each Puma worker has its own pool, so
`-w 4 --threads 1:4` against a pool of 5 is correctly configured.

## The thing that is easy to get wrong

**Capability belongs to the collector, not the mode.**

An `:http` run against a remote target that does not load the gem has the
*same transport* as this one and dramatically less capability — no query data
at all. Reports consult the capability record rather than the execution mode,
so that run says what it could not see instead of reporting zeroes.

If you point `http_target_url` at something non-loopback, Loadwright treats
it as production-adjacent: the local `Rails.env` describes the wrong process
entirely, so the target has to identify itself before anything is sent. Its
self-report can *refuse* a run and never *approve* one.

## Orphaned servers

`SIGKILL` cannot be trapped. If a run is hard-killed, the Puma it booted
survives and keeps holding your development database open.

Every `:http` run therefore reaps orphans before booting: it reads the
pidfile each run leaves behind and kills a server whose harness is gone.
Never on a PID match alone — the recorded process start time must match too,
and a record written by a different machine is left entirely alone.
