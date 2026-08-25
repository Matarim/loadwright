# frozen_string_literal: true

# Mutation audit of the safety-critical behaviours. See MUTATION_AUDIT.md beside this
# file for what it is for and why each mutation must prove itself.
#
#   bundle exec ruby tools/mutation_audit.rb
#
# TWO PROPERTIES THIS SCRIPT MUST HAVE, both learned the hard way:
#
# 1. IT NEVER TOUCHES THE REAL WORKING TREE. The first version mutated files in place
#    and restored them in an `ensure`, which is fine until the process is killed — and
#    it was, by a timeout. It left coverage.rb ZERO BYTES and three orphaned Puma
#    processes holding the fixture database. A tool whose failure mode is "silently
#    disables a safety check in your working tree" has no business being pointed at a
#    safety suite. It now copies the repo, mutates the copy, and throws it away.
#
# 2. EVERY MUTATION PROVES IT CHANGED SOMETHING FIRST. The failure mode of a
#    hand-rolled audit is a mutation that does not actually change behaviour: the spec
#    stays green and looks like a coverage gap. That happened on the first run — the
#    Layer 1b adjacency mutation inserted a dead line and returned the same value. It
#    was caught by reading the diff, which is not a method. Each mutation now carries a
#    `proof` whose observable value must differ before and after, or the mutation is
#    reported NO_OP: a defect in the audit, not a pass for the spec.
#
# It also deliberately targets NARROW spec files. Running the end-to-end spec here
# would boot Puma once per mutation, and a killed run would orphan every one of them.

require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

SOURCE_ROOT = File.expand_path("..", __dir__)

Mutation = Struct.new(:name, :file, :from, :to, :spec, :proof, keyword_init: true)

# `proof` is Ruby evaluated in a fresh subprocess against the MUTATED COPY, printing one
# line. It must exercise the mutated path and return something that visibly differs.
MUTATIONS = [
  Mutation.new(
    name: "Layer 3 cond 1: allow_production check removed",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: "        unless config.allow_production\n",
    to: "        if false\n",
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Configuration.new
      c.confirmation_phrase = "App"
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: c, confirmation: Object.new.tap { |o| def o.obtain!(*, **) = true },
        env: { "RAILS_ENV" => "production" }, rails_env: nil, hostname: "mac", stdout: StringIO.new
      )
      begin
        g.approve!(risk_acknowledged: true, execute: true).conditions_cleared.inspect
      rescue Loadwright::SafetyError
        "refused"
      end
    PROOF
  ),
  Mutation.new(
    name: "Layer 3 cond 2: typed confirmation not obtained",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: "        @confirmation.obtain!(phrase, prompt: primary_prompt(environment, adjacency))\n",
    to: "        # mutated: confirmation skipped\n",
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Configuration.new
      c.confirmation_phrase = "App"
      c.allow_production = true
      refuser = Object.new
      def refuser.obtain!(*, **) = raise(Loadwright::SafetyError, "would refuse")
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: c, confirmation: refuser, env: { "RAILS_ENV" => "production" },
        rails_env: nil, hostname: "mac", stdout: StringIO.new
      )
      begin
        g.approve!(risk_acknowledged: true, execute: true).conditions_cleared.inspect
      rescue Loadwright::SafetyError
        "refused"
      end
    PROOF
  ),
  Mutation.new(
    name: "Layer 3 cond 3: --i-understand-the-risk check removed",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: "        unless risk_acknowledged\n",
    to: "        if false\n",
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Configuration.new
      c.confirmation_phrase = "App"
      c.allow_production = true
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: c, confirmation: Object.new.tap { |o| def o.obtain!(*, **) = true },
        env: { "RAILS_ENV" => "production" }, rails_env: nil, hostname: "mac", stdout: StringIO.new
      )
      begin
        g.approve!(risk_acknowledged: false, execute: true).conditions_cleared.inspect
      rescue Loadwright::SafetyError
        "refused"
      end
    PROOF
  ),
  Mutation.new(
    name: "Layer 3 cond 4: second heuristic confirmation removed",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: "        if heuristics.any?\n          @confirmation.obtain!(phrase, prompt: heuristic_prompt(heuristics))",
    to: "        if false\n          @confirmation.obtain!(phrase, prompt: heuristic_prompt(heuristics))",
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Configuration.new
      c.confirmation_phrase = "App"
      c.allow_production = true
      counter = Object.new
      def counter.calls = (@calls ||= 0)
      def counter.obtain!(*, **) = (@calls = calls + 1) && true
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: c, confirmation: counter, env: { "RAILS_ENV" => "production" },
        rails_env: nil, hostname: "prod-web-04", stdout: StringIO.new
      )
      g.approve!(risk_acknowledged: true, execute: true)
      "prompts=\#{counter.calls}"
    PROOF
  ),
  Mutation.new(
    name: "confirmation_phrase: generic fallback substituted",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: "        phrase = config.confirmation_phrase\n",
    to: "        phrase = config.confirmation_phrase || \"I UNDERSTAND\"\n",
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Configuration.new
      c.confirmation_phrase = nil
      c.allow_production = true
      seen = Object.new
      def seen.phrase = @phrase
      def seen.obtain!(p, **) = (@phrase = p) && true
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: c, confirmation: seen, env: { "RAILS_ENV" => "production" },
        rails_env: nil, hostname: "mac", stdout: StringIO.new
      )
      begin
        g.approve!(risk_acknowledged: true, execute: true)
        "prompted with \#{seen.phrase.inspect}"
      rescue Loadwright::SafetyError
        "refused"
      end
    PROOF
  ),
  Mutation.new(
    name: "Layer 1: environment allowlist ignored",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: "        config.enabled_environments.map(&:to_s).include?(environment.to_s)\n      end",
    to: "        true\n      end",
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: Loadwright::Configuration.new,
        confirmation: Object.new.tap { |o| def o.obtain!(*, **) = true },
        env: { "RAILS_ENV" => "production" }, rails_env: nil, hostname: "mac", stdout: StringIO.new
      )
      begin
        g.approve!.production_adjacent.inspect
      rescue Loadwright::SafetyError
        "refused"
      end
    PROOF
  ),
  Mutation.new(
    name: "Layer 1: unset environment treated as development",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: '        value.to_s.strip.empty? ? "unknown" : value.to_s',
    to: '        value.to_s.strip.empty? ? "development" : value.to_s',
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: Loadwright::Configuration.new,
        confirmation: Object.new.tap { |o| def o.obtain!(*, **) = true },
        env: {}, rails_env: nil, hostname: "mac", stdout: StringIO.new
      )
      begin
        g.approve!.environment
      rescue Loadwright::SafetyError => e
        e.message[/"[a-z]+"/].to_s
      end
    PROOF
  ),
  # The mutation that was a NO-OP on the first run. Now a real change, and proven so.
  Mutation.new(
    name: "Layer 1b: remote target no longer production-adjacent",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: :regexp_adjacency,
    to: "        [report, nil]\n",
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Configuration.new
      c.confirmation_phrase = "App"
      c.http_target_url = "http://staging.example.com"
      c.allow_remote_http_target = true
      identifier = Object.new
      def identifier.identify!(url)
        Loadwright::Safety::RemoteTargetIdentifier::Report.new(
          url: url, host: "staging.example.com", environment: "development",
          version: "0.0.1", enabled_here: true
        )
      end
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: c, confirmation: Object.new.tap { |o| def o.obtain!(*, **) = true },
        identifier: identifier, env: { "RAILS_ENV" => "development" },
        rails_env: nil, hostname: "mac", stdout: StringIO.new
      )
      begin
        g.approve!.production_adjacent.inspect
      rescue Loadwright::SafetyError
        "refused"
      end
    PROOF
  ),
  Mutation.new(
    name: "Layer 1b: allow_remote_http_target check removed",
    file: "lib/loadwright/safety/environment_guard.rb",
    from: "        unless config.allow_remote_http_target\n",
    to: "        if false\n",
    spec: "spec/loadwright/safety/environment_guard_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Configuration.new
      c.confirmation_phrase = "App"
      c.http_target_url = "http://staging.example.com"
      identifier = Object.new
      def identifier.identify!(url) = raise(Loadwright::SafetyError, "consulted")
      g = Loadwright::Safety::EnvironmentGuard.new(
        config: c, confirmation: Object.new.tap { |o| def o.obtain!(*, **) = true },
        identifier: identifier, env: { "RAILS_ENV" => "development" },
        rails_env: nil, hostname: "mac", stdout: StringIO.new
      )
      begin
        g.approve!.inspect
      rescue Loadwright::SafetyError => e
        e.message.include?("allow_remote_http_target is false") ? "refused-early" : "consulted-target"
      end
    PROOF
  ),
  Mutation.new(
    name: "Layer 1b: disallowed self-reported environment accepted",
    file: "lib/loadwright/safety/remote_target_identifier.rb",
    from: "        return if allowed.include?(report.environment)",
    to: "        return",
    spec: "spec/loadwright/safety/remote_target_identifier_spec.rb",
    proof: <<~PROOF
      i = Loadwright::Safety::RemoteTargetIdentifier.new(
        config: Loadwright::Configuration.new,
        fetcher: ->(*) { '{"env":"production","loadwright_version":"1","enabled_here":false}' }
      )
      begin
        i.identify!("http://api.acme.com").environment
      rescue Loadwright::SafetyError
        "refused"
      end
    PROOF
  ),
  Mutation.new(
    name: "identity endpoint: payload widened",
    file: "lib/loadwright/execution/identity_endpoint.rb",
    from: "          \"enabled_here\" => enabled_here?(config)\n        }",
    to: "          \"enabled_here\" => enabled_here?(config),\n          \"sql\" => \"SELECT 1\"\n        }",
    spec: "spec/loadwright/execution/identity_endpoint_spec.rb",
    proof: "Loadwright::Execution::IdentityEndpoint.payload.keys.sort.inspect"
  ),
  Mutation.new(
    name: "dry run: transport issues requests anyway",
    file: "lib/loadwright/execution/transport/base.rb",
    from: "          if dry_run\n",
    to: "          if false\n",
    spec: "spec/loadwright/execution/transport/null_spec.rb",
    proof: <<~PROOF
      t = Loadwright::Execution::Transport::Null.new(config: Loadwright::Configuration.new, dry_run: true)
      begin
        t.issue(Loadwright::Execution::Request.new(verb: :get, path: "/x"))
        "issued=\#{t.issued_count}"
      rescue Loadwright::Execution::Transport::Base::DryRunViolation
        "refused"
      end
    PROOF
  ),
  Mutation.new(
    name: "split: contention counted in the breaker's numerator",
    file: "lib/loadwright/engine/circuit_breaker.rb",
    from: "          @observations += 1\n          @contention_events += 1",
    to: "          @observations += 1\n          @errors += 1\n          @contention_events += 1",
    spec: "spec/loadwright/engine/circuit_breaker_spec.rb",
    proof: <<~PROOF
      b = Loadwright::Engine::CircuitBreaker.new(config: Loadwright::Configuration.new)
      100.times { b.record_contention }
      "tripped=\#{b.tripped?} errors=\#{b.errors}"
    PROOF
  ),
  Mutation.new(
    name: "carve-out: ConnectionTimeoutError at concurrency 1 routed to guard",
    file: "lib/loadwright/engine/resource_guard.rb",
    from: "        return :endpoint_finding if name == POOL_EXHAUSTION && concurrency.to_i <= 1",
    to: "        # mutated: carve-out removed",
    spec: "spec/loadwright/engine/resource_guard_spec.rb",
    proof: <<~PROOF
      module ActiveRecord; class ConnectionTimeoutError < StandardError; end; end
      g = Loadwright::Engine::ResourceGuard.new(config: Loadwright::Configuration.new, stdout: StringIO.new)
      g.classify(ActiveRecord::ConnectionTimeoutError.new("t"), concurrency: 1).inspect
    PROOF
  ),
  Mutation.new(
    name: "validity gate: error status accepted as healthy",
    file: "lib/loadwright/analysis/response_validator.rb",
    from: "        if failed_status?(endpoint, response)",
    to: "        if false",
    spec: "spec/loadwright/analysis/response_validator_spec.rb",
    proof: <<~PROOF
      e = Loadwright::Discovery::Endpoint.new(path: "/x", verb: :get, source: :openapi)
      r = Loadwright::Execution::RawResponse.new(
        request: Loadwright::Execution::Request.new(verb: :get, path: "/x"),
        status: 403, headers: { "content-type" => "application/json" }, body: "{}"
      )
      v = Loadwright::Analysis::ResponseValidator.new(config: Loadwright::Configuration.new)
      verdict = v.validate(endpoint: e, response: r)
      "valid=\#{verdict.valid?} reason=\#{verdict.reason.inspect}"
    PROOF
  ),
  Mutation.new(
    name: "validity gate: empty-with-seeded-data accepted",
    file: "lib/loadwright/analysis/response_validator.rb",
    from: "        if empty_with_seeded_data?(record_count, seeded_count)",
    to: "        if false",
    spec: "spec/loadwright/analysis/response_validator_spec.rb",
    proof: <<~PROOF
      e = Loadwright::Discovery::Endpoint.new(path: "/x", verb: :get, source: :openapi)
      r = Loadwright::Execution::RawResponse.new(
        request: Loadwright::Execution::Request.new(verb: :get, path: "/x"),
        status: 200, headers: { "content-type" => "application/json" }, body: "[]"
      )
      v = Loadwright::Analysis::ResponseValidator.new(config: Loadwright::Configuration.new)
      verdict = v.validate(endpoint: e, response: r, seeded_count: 200)
      "valid=\#{verdict.valid?} reason=\#{verdict.reason.inspect}"
    PROOF
  ),
  # The comparison layer's version of the validity gate above, and the same failure
  # mode: a number reported with a verdict the data does not support. Removing this
  # guard turns "your endpoint returned 40% fewer records" into "your query count
  # improved" -- which reads as a fix and gets acted on as one.
  Mutation.new(
    name: "comparison: query delta keeps its verdict when the record count moved",
    file: "lib/loadwright/history/comparator.rb",
    from: "        return :unattributable if records_moved",
    to: "        # mutated: denominator gate removed",
    spec: "spec/loadwright/history/comparator_spec.rb",
    proof: <<~PROOF
      c = Loadwright::History::Comparator.new(config: Loadwright::Configuration.new)
      d = c.send(:count_delta, "GET /a", "cell", :queries, 31, 6, records_moved: true)
      "verdict=\#{d.verdict.inspect}"
    PROOF
  ),
  # An endpoint that stopped returning things is a defect however fast it got.
  Mutation.new(
    name: "comparison: a collapse in returned records is not called a regression",
    file: "lib/loadwright/history/comparator.rb",
    from: "          verdict: after < before ? :regression : :unattributable,",
    to: "          verdict: :unattributable,",
    spec: "spec/loadwright/history/comparator_spec.rb",
    proof: <<~PROOF
      c = Loadwright::History::Comparator.new(config: Loadwright::Configuration.new)
      d = c.send(:records_delta, "GET /a", "cell", 30, 0)
      "verdict=\#{d.verdict.inspect}"
    PROOF
  ),
  Mutation.new(
    name: "coverage: advisory class allowed to escalate",
    file: "lib/loadwright/coverage.rb",
    from: "      return false if ADVISORY_CLASSES.include?(finding_class)\n",
    to: "",
    spec: "spec/loadwright/coverage_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Coverage.new(
        pattern_match: :available, payload_growth: :available,
        query_response_comparison: [:unavailable, "none recorded"]
      )
      "complete=\#{c.complete?} uncovered=\#{c.uncovered_classes.inspect}"
    PROOF
  ),
  Mutation.new(
    name: "coverage: not_applicable treated as a gap",
    file: "lib/loadwright/coverage.rb",
    from: "      when nil then Detector.new(name: name, state: :not_applicable, reason: nil)",
    to: "      when nil then Detector.new(name: name, state: :unavailable, reason: \"not attempted\")",
    spec: "spec/loadwright/coverage_spec.rb",
    proof: <<~PROOF
      c = Loadwright::Coverage.new(pattern_match: :available, payload_growth: :available,
                                   query_response_comparison: :available)
      "complete=\#{c.complete?} uncovered=\#{c.uncovered_classes.inspect}"
    PROOF
  ),
  Mutation.new(
    name: "secret file: run id no longer checked",
    file: "lib/loadwright/execution/server_manager.rb",
    from: "        if expected_run_id && run_id != expected_run_id.to_s",
    to: "        if false",
    spec: "spec/loadwright/execution/server_manager_spec.rb",
    proof: <<~PROOF
      require "tmpdir"
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s")
        File.write(path, "an-older-run\\nabc123")
        File.chmod(0o600, path)
        Loadwright::Execution::ServerManager.read_secret_file(path, "this-run").inspect
      end
    PROOF
  ),
  Mutation.new(
    name: "secret file: written world-readable",
    file: "lib/loadwright/execution/server_manager.rb",
    from: "        if mode & 0o077 != 0",
    to: "        if false",
    spec: "spec/loadwright/execution/server_manager_spec.rb",
    proof: <<~PROOF
      require "tmpdir"
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s")
        File.write(path, "r\\nabc123")
        File.chmod(0o644, path)
        Loadwright::Execution::ServerManager.read_secret_file(path, "r").inspect
      end
    PROOF
  ),
  # The reaping rules. Each of these mutations describes a way the gem could kill
  # something the developer cares about.
  Mutation.new(
    name: "reaping: kills on PID alone, ignoring process start time",
    file: "lib/loadwright/execution/server_manager.rb",
    from: "          ServerManager.process_start_time(pid) == started_at\n",
    to: "          true\n",
    spec: "spec/loadwright/execution/server_manager_spec.rb",
    proof: <<~PROOF
      id = Loadwright::Execution::ServerManager::ProcessIdentity.new(
        pid: Process.pid, started_at: "Mon Jan  1 00:00:00 2001"
      )
      "recycled_pid_looks_current=\#{id.current?}"
    PROOF
  ),
  Mutation.new(
    name: "reaping: a concurrent run's server treated as an orphan",
    file: "lib/loadwright/execution/server_manager.rb",
    from: "          if harness&.current?",
    to: "          if false",
    spec: "spec/loadwright/execution/server_manager_spec.rb",
    proof: <<~PROOF
      require "tmpdir"
      require "fileutils"
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "loadwright-run-proof")
        FileUtils.mkdir_p(dir)
        # A server that is this very process, and a harness that is also alive: a
        # concurrent run. Nothing here may be reaped.
        start = Loadwright::Execution::ServerManager.process_start_time(Process.pid)
        host = Loadwright::Execution::ServerManager.current_hostname
        File.write(File.join(dir, "server.pid"),
                   "host \#{host}\nserver \#{Process.pid} \#{start}\n" \
                   "harness \#{Process.pid} \#{start}\nurl http://x\n")
        killed = []
        Loadwright::Execution::ServerManager.define_singleton_method(:terminate_pid) do |pid|
          killed << pid
          true
        end
        Loadwright::Execution::ServerManager.reap_orphans!(stdout: StringIO.new, tmpdir: tmp)
        "would_kill=\#{killed.inspect}"
      end
    PROOF
  ),
  Mutation.new(
    name: "reaping: acts on a record written by another machine",
    file: "lib/loadwright/execution/server_manager.rb",
    from: "          next unless record[:host] == current_hostname",
    to: "          next unless true",
    spec: "spec/loadwright/execution/server_manager_spec.rb",
    proof: <<~PROOF
      require "tmpdir"
      require "fileutils"
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "loadwright-run-proof")
        FileUtils.mkdir_p(dir)
        # A live process recorded by a DIFFERENT host, with a dead harness. Every
        # local signal reads "orphan"; only the hostname says it is not ours.
        start = Loadwright::Execution::ServerManager.process_start_time(Process.pid)
        File.write(File.join(dir, "server.pid"),
                   "host some-other-machine\nserver \#{Process.pid} \#{start}\n" \
                   "harness 1 stale\nurl http://x\n")
        killed = []
        Loadwright::Execution::ServerManager.define_singleton_method(:terminate_pid) do |pid|
          killed << pid
          true
        end
        Loadwright::Execution::ServerManager.reap_orphans!(stdout: StringIO.new, tmpdir: tmp)
        "would_kill=\#{killed.inspect}"
      end
    PROOF
  ),
  # EXPLAIN ANALYZE EXECUTES THE STATEMENT. On a write, that performs the write --
  # against a developer's database, from a tool whose premise is that it is safe to
  # run locally.
  Mutation.new(
    name: "EXPLAIN: ANALYZE run on a write statement",
    file: "lib/loadwright/analysis/explain_analyzer.rb",
    from: "        analyzed = analyzable?(candidate.sql)",
    to: "        analyzed = true",
    spec: "spec/loadwright/analysis/explain_analyzer_spec.rb",
    proof: <<~PROOF
      connection = Object.new
      connection.instance_variable_set(:@statements, [])
      def connection.adapter_name = "PostgreSQL"
      def connection.statements = @statements
      def connection.select_all(sql) = (@statements << sql) && []
      def connection.execute(sql) = @statements << sql
      analyzer = Loadwright::Analysis::ExplainAnalyzer.new(
        config: Loadwright::Configuration.new, connection: connection, stdout: StringIO.new
      )
      candidate = Loadwright::Analysis::ExplainAnalyzer::Candidate.new(
        endpoint_key: "DELETE /posts/1", fingerprint: "fp",
        sql: "DELETE FROM posts WHERE id = 1", duration_ms: 900.0
      )
      analyzer.analyze([candidate])
      "would_execute=\#{connection.statements.grep(/ANALYZE/).inspect}"
    PROOF
  ),
  Mutation.new(
    name: "cleanup: deletes whole tables instead of tracked ids",
    file: "lib/loadwright/seeding/factory_bot_seeder.rb",
    from: "          deleted += model.where(id: slice).delete_all",
    to: "          deleted += model.delete_all && slice.length",
    spec: "spec/loadwright/seeding/factory_bot_seeder_spec.rb",
    proof: :source_text
  ),
  Mutation.new(
    name: "initializer: `if defined?(Loadwright)` guard removed",
    file: "lib/generators/loadwright/templates/loadwright.rb.tt",
    from: "if defined?(Loadwright)\n",
    to: "if true # mutated\n",
    spec: "spec/loadwright/documentation_drift_spec.rb",
    proof: :source_text
  )
].freeze

def resolve_from(mutation, original)
  case mutation.from
  when :regexp_adjacency
    original[/        \[report, "http_target_url.*?grants nothing\)"\]\n/m]
  else
    mutation.from
  end
end

# Runs `code` in a fresh process against the COPY, returning its last line. Fresh
# because the mutated file has to be read from disk.
def observe(root, code)
  script = <<~SCRIPT
    $LOAD_PATH.unshift(File.join(#{root.inspect}, "lib"))
    require "stringio"
    require "loadwright"
    begin
      puts(begin
        #{code}
      end.to_s)
    rescue Exception => e
      puts "RAISED \#{e.class}"
    end
  SCRIPT

  out, = Open3.capture3(RbConfig.ruby, "-e", script, chdir: root)
  out.lines.last.to_s.strip
end

def copy_repo(destination)
  Dir.chdir(SOURCE_ROOT) do
    tracked = `git ls-files`.split("\n")
    tracked.each do |relative|
      target = File.join(destination, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(relative, target)
    end
  end
  # Bundler needs the lockfile, which is gitignored in this repo.
  lock = File.join(SOURCE_ROOT, "Gemfile.lock")
  FileUtils.cp(lock, File.join(destination, "Gemfile.lock")) if File.file?(lock)
end

def run_spec(root, spec)
  system(
    { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
    "bundle", "exec", "rspec", *spec.split, "--no-color", "--format", "progress",
    chdir: root, out: File::NULL, err: File::NULL
  )
end

# REFUSES TO START ON A DIRTY TREE, unless told otherwise.
#
# The audit copies the repo now, so it cannot itself damage the working tree. But that
# only closes the specific trap. The general exposure is that RECOVERY from a problem in
# destructive tooling tends to be destructive too: cleaning up after the in-place
# version, a `git checkout -- lib/` scoped one directory too wide wiped two completed
# pieces of work. Nothing was lost, because they could be redone — but only because they
# were small. Had there been a commit to return to, none of it would have been needed.
#
# So: the audit's job is to prove the safety specs are real, and a tool that can cost
# you uncommitted work while doing it undermines its own purpose. Commit first.
def check_clean_tree!
  return if ENV["ALLOW_DIRTY"] == "1"

  dirty = `git -C #{SOURCE_ROOT.shellescape} status --porcelain`.strip
  return if dirty.empty?

  warn <<~MESSAGE
    Refusing to run the mutation audit: the working tree has uncommitted changes.

    #{dirty.lines.first(12).map { |l| "  #{l.chomp}" }.join("\n")}
    #{"  ...and more" if dirty.lines.length > 12}

    The audit only mutates a throwaway copy, so it cannot damage these files directly.
    It refuses anyway, because recovering from a problem in destructive tooling tends to
    be destructive too — and a commit is the thing that makes recovery free. Commit or
    stash first.

    To run anyway: ALLOW_DIRTY=1 bundle exec rake mutation_audit
  MESSAGE
  exit 2
end

check_clean_tree!

results = []

Dir.mktmpdir("loadwright-mutation-") do |root|
  warn "copying the repository to #{root} — the working tree is never modified"
  copy_repo(root)

  MUTATIONS.each_with_index do |mutation, index|
    warn format("[%<n>2d/%<total>d] %<name>s", n: index + 1, total: MUTATIONS.length, name: mutation.name)

    path = File.join(root, mutation.file)
    original = File.read(path)
    from = resolve_from(mutation, original)

    if from.nil? || !original.include?(from)
      results << [mutation.name, :ANCHOR_MISSING, nil]
      next
    end

    mutated = original.sub(from, mutation.to)

    # THE PROOF STEP. A mutation that changes nothing observable proves nothing about
    # the spec, and scoring it either way would be the audit lying to itself.
    if mutation.proof == :source_text
      before, after = original, mutated
    else
      before = observe(root, mutation.proof)
      File.write(path, mutated)
      after = observe(root, mutation.proof)
    end

    File.write(path, mutated)

    if before == after
      results << [mutation.name, :NO_OP, "proof unchanged: #{before.to_s[0, 40].inspect}"]
      File.write(path, original)
      next
    end

    caught = !run_spec(root, mutation.spec)
    detail = mutation.proof == :source_text ? "source changed" : "#{before.inspect} -> #{after.inspect}"
    results << [mutation.name, caught ? :caught : :STAYED_GREEN, detail]

    File.write(path, original)
  end
end

puts
puts "=" * 108
results.each do |name, outcome, detail|
  label = { caught: "RED", NO_OP: "NO-OP", STAYED_GREEN: "GREEN!", ANCHOR_MISSING: "ANCHOR?" }.fetch(outcome)
  puts format("%-8s %-58s %s", label, name, detail.to_s[0, 40])
end
puts "=" * 108

problems = results.reject { |_, outcome, _| outcome == :caught }
if problems.empty?
  puts "All #{results.length} mutations changed observable behaviour and were caught."
  exit 0
end

puts "PROBLEMS:"
problems.each { |name, outcome, detail| puts "  #{outcome}: #{name}\n    #{detail}" }
exit 1
