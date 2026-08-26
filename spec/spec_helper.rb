# frozen_string_literal: true

require "loadwright"
require "stringio"
require "json"

# Paths used by the documentation-drift and architecture specs. Defined here so
# a repository reorganisation breaks in one place rather than five.
module SpecPaths
  ROOT = File.expand_path("..", __dir__)

  LIB              = File.join(ROOT, "lib", "loadwright")
  INITIALIZER_TT   = File.join(ROOT, "lib", "generators", "loadwright", "templates", "loadwright.rb.tt")
  AGENTS_MD        = File.join(ROOT, "AGENTS.md")
  README_MD        = File.join(ROOT, "README.md")
  REFERENCES       = File.join(ROOT, ".claude", "skills", "loadwright-development", "references")

  module_function

  def read(path) = File.read(path)
end

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |path| require path }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Configuration is global state; no example may leak into another.
  config.before { Loadwright.reset_configuration! }

  # So is the current request id. An example that opens a request without closing it
  # leaves this fiber marked as belonging to that request, and the NEXT example's
  # instrumented events get attributed to it — which shows up as an unrelated spec
  # failing under some seeds and not others. (The production equivalent of this leak
  # is fixed in ExecutionContext#issue and CollectorMiddleware, both with an
  # `ensure`; this hook keeps the suite from depending on those being called.)
  config.before { Loadwright::Instrumentation::CurrentRequest.clear! }

  # Same reason: a spec that opens a field frame without closing it would attribute
  # the NEXT example's queries to a resolver it never touched.
  config.before { Loadwright::Instrumentation::CurrentField.clear! }
  config.after { Loadwright::Instrumentation::CurrentRequest.clear! }
end
