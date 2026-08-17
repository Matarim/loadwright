# frozen_string_literal: true

# MUTATING ENDPOINTS — the opt-in, and the four things it makes possible.
#
# READ THIS BEFORE COPYING IT. Everywhere else in the example set, the worst outcome
# of a misconfiguration is a bad measurement. Here it is a side effect in the real
# world, and the environment gate does nothing about it: hitting POST /orders five
# hundred times can send five hundred real emails, enqueue five hundred real jobs,
# fire five hundred webhooks at a partner's sandbox, and burn real third-party API
# quota — from a laptop, in development, with every environment check passing.
#
# That is why containment is a separate subsystem with its own abort, and why it is
# ON BY DEFAULT. Do not turn a measure off to make a run proceed. Turn it off only
# when you have decided the specific consequence is acceptable.
if defined?(Loadwright)
  Loadwright.configure do |config|
    # THE OPT-IN. Without this, mutating verbs are discovered and skipped, and the
    # report lists them as skipped rather than omitting them.
    config.allow_mutating_requests = true

    # ---- containment: all three on, and Loadwright ABORTS if any cannot be enforced

    # ActionMailer to :test. Deliveries are RECORDED instead of sent, which is what
    # turns suppression into a measurement.
    config.suppress_mail_delivery = true

    # ActiveJob to :test. Same trade: jobs are recorded, not performed. A request
    # that enqueues 200 jobs is a finding in its own right, and containment is the
    # only reason you can see it.
    config.suppress_background_jobs = true
    config.jobs_enqueued_warning_threshold = 10

    # Outbound HTTP blocked except to the allowlist. Requires webmock; without it
    # this measure is unenforceable and the run aborts rather than proceeding while
    # you believe you are contained.
    config.block_outbound_http = true
    config.outbound_http_allowlist = %w[localhost 127.0.0.1]

    # WARN-AND-CONTINUE WOULD BE THE WRONG DEFAULT. You believe you are contained;
    # silently not being contained is the failure that mails five hundred real
    # customers from a dev box. An aborted run that annoys you is the better outcome.
    config.abort_if_containment_unavailable = true

    # ---- the measurement confound you cannot configure away

    # Firing POST /orders 500 times means request 500 runs against a table holding
    # 499 more rows than request 1, so latency drift reflects DATA GROWTH rather than
    # concurrency. Keep the per-cell count low so the confound stays small, and read
    # the trend as a confounded one — the report discloses it.
    config.requests_per_endpoint_per_level = 10
    config.scale_factors = [10]
    config.concurrency_levels = [1]

    config.factory_map = { "order" => { factory: :order } }

    # Rows Loadwright created are deleted by id. Rows YOUR ENDPOINTS created are not
    # Loadwright's to track, and it will not guess — a POST that writes to three
    # tables leaves rows behind, and that is your cleanup, not the tool's.
    config.seed_cleanup_strategy = :delete_created_rows
  end
end
