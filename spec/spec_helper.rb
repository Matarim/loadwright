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
end
