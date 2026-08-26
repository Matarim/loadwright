# frozen_string_literal: true

# FIXTURE. A plain Rack app with several endpoints behind one Rails route.
MountedApi = lambda do |env|
  path = env["PATH_INFO"]
  body = case path
         when %r{\A/widgets/[^/]+/customer\z} then { name: "a customer" }
         when %r{\A/widgets/[^/]+\z} then { widget: path.split("/").last }
         else { error: "not found" }
         end
  status = body[:error] ? 404 : 200
  [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
end
