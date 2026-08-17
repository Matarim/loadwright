# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

namespace :spec do
  # Runs the suite under several fixed seeds.
  #
  # THIS IS NOT BELT-AND-BRACES. examples/sample_app boots a real Rails application
  # and a real ActiveRecord connection into the same process as the suite, and once
  # it has, `Rails` and `ActiveRecord` are defined for every example that runs
  # afterwards. Any spec whose premise is "Rails is not loaded" therefore passes or
  # fails depending on ORDER.
  #
  # That is not hypothetical: it silently disabled twenty-two of the safety guard's
  # examples, including every "refuses to run in production" case, because the guard
  # read ::Rails.env and ignored the injected environment. They passed for the wrong
  # reason and a single-seed run never noticed. A multi-seed run found it in one go.
  SEEDS = [1, 7, 42, 99, 1234].freeze

  desc "Run the suite under several seeds, to catch order-dependent examples"
  task :seeds do
    failures = SEEDS.reject do |seed|
      puts "\n== seed #{seed} " + ("=" * 40)
      system("bundle", "exec", "rspec", "--seed", seed.to_s)
    end

    abort "\nOrder-dependent failures under seed(s): #{failures.join(', ')}" if failures.any?

    puts "\nAll #{SEEDS.length} seeds green."
  end
end

task default: :spec
