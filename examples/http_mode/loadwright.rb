# frozen_string_literal: true

# :HTTP MODE — a real server, real sockets, real thread contention.
#
# Who this is for: someone asking a CAPACITY question. ":in_process" (the default)
# answers query-structure questions with zero setup and is the right mode for most
# questions most of the time. It cannot answer "what happens at concurrency 20",
# because there is no server thread pool to contend for — the harness IS the app.
#
# WHAT THIS MODE ADDS
#   * latency under real concurrency
#   * connection pool exhaustion, observed rather than inferred
#   * true client latency, including the middleware stack and the socket
#   * clean memory attribution (the app has its own process)
#
# WHAT IT COSTS
#   * a real Puma boot per run, and the health-poll wait for it
#   * correlation machinery: the harness cannot read the app's notifications
#     directly, so metrics come back over a guarded endpoint
#
# WHAT DOES NOT CHANGE. Capability belongs to the COLLECTOR, not the mode. An :http
# run against a remote target that does not load the gem has the same transport as
# this one and dramatically LESS capability — no query data at all. Reports consult
# the capability record rather than the mode, so a degraded remote run says what it
# could not see instead of reporting zeroes.
if defined?(Loadwright)
  Loadwright.configure do |config|
    config.execution_mode = :http

    # $PORT is filled in by Loadwright when it spawns the child. The collector
    # secret travels as a FILE PATH in the environment, never as the secret itself:
    # an environment variable holding it is readable via `ps` by any local user.
    config.http_server_command = "bundle exec puma -p $PORT --threads 1:5"

    # How long to wait for the boot before giving up. The health probe is the
    # identity endpoint, which answering proves both that the process is up AND
    # that it loaded the gem.
    config.http_boot_timeout = 30

    # THE FINDING THIS MODE EXISTS FOR. More server threads than pool connections
    # means threads queue for a connection under load and latency collapses in a way
    # that looks exactly like a slow database and is not.
    #
    # Reported even when no contention was observed during the run: it is a latent
    # problem, a run at concurrency 5 will not provoke it, and stating it costs
    # nothing.
    config.check_pool_vs_server_threads = true
    config.track_connection_pool = true

    config.concurrency_levels = [1, 5, 20]
    config.requests_per_endpoint_per_level = 100

    config.factory_map = { "post" => { factory: :post, trait: :with_comments } }
    config.scale_factors = [10, 100]

    # Leave this alone unless you are pointing at a server you did not boot. A
    # non-loopback target means the local Rails.env describes the wrong process
    # entirely, and Loadwright treats it as production-adjacent and makes the target
    # identify itself before proceeding.
    config.http_target_url = nil
    config.allow_remote_http_target = false
  end
end
