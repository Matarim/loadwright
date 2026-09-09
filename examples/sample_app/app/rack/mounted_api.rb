# frozen_string_literal: true

# FIXTURE. A plain Rack app with several endpoints behind one Rails route.
#
# IT EMITS NO process_action EVENT, which is the point of it. Grape, Sinatra and Roda
# all look like this, and a request through here has no controller, no view runtime,
# and no Breakdown -- so anything that reads a request's instrumentation off the
# controller notification silently produces nothing for two thirds of an API that
# mounts one of them.
#
# It announces its own work through ActiveSupport::Notifications, the way an
# application instruments a calculation it suspects is expensive. That is what the
# `other` attribution is supposed to name.
MountedApi = lambda do |env|
  path = env["PATH_INFO"]
  body = case path
         when %r{\A/widgets/[^/]+/customer\z} then { name: "a customer" }
         when %r{\A/widgets/[^/]+\z}
           ActiveSupport::Notifications.instrument("calculate_payoff.mounted_api") do
             { widget: path.split("/").last }
           end
         else { error: "not found" }
         end
  status = body[:error] ? 404 : 200
  [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
end
