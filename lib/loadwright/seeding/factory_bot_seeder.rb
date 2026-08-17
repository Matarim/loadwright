# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Seeding
    # Populates the database through the APP'S OWN FactoryBot factories, at each
    # scale factor, and cleans up only what it created.
    #
    # THREE RULES, all of them about not damaging the developer's machine or their
    # trust:
    #
    # 1. NEVER TRUNCATE. Cleanup deletes only the rows Loadwright inserted, tracked
    #    by id. A developer's local database holds seed data, fixtures, and
    #    hand-crafted state they may have spent real time on; wiping their tables
    #    because they ran a diagnostic tool is an unacceptable outcome. There is a
    #    spec asserting the SQL actually executed contains no TRUNCATE.
    #
    # 2. DO NOT ROUTE AROUND A UNIQUENESS COLLISION. If `create_list` raises on a
    #    unique constraint, the factory is missing a `sequence` for that field. The
    #    correct response is to name the factory and the field, suggest the
    #    sequence, and SKIP that resource — not to generate a unique value behind
    #    the user's back, which produces data that does not match how the app is
    #    actually used. `config.unique_field_generator` exists only for resources
    #    with no factory at all.
    #
    # 3. SEED IN BATCHES, UNDER THE GUARD. `create_list(:post, 200)` with callbacks,
    #    counter caches, or search-index hooks can lock the table or exhaust the
    #    pool by itself. Batches of config.seed_batch_size with a health check
    #    between them, and contention during seeding backs off and retries the batch
    #    rather than aborting the run.
    class FactoryBotSeeder
      # What was created for one resource at one scale factor.
      Seeded = Struct.new(:resource, :factory, :requested, :created, :ids, :model, keyword_init: true) do
        def complete? = created >= requested
      end

      # A resource that could not be seeded, and the actionable reason.
      Failure = Struct.new(:resource, :factory, :requested, :created, :reason, :remedy, keyword_init: true) do
        def to_h = { resource: resource, factory: factory, requested: requested, created: created,
                     reason: reason, remedy: remedy }
      end

      # Uniqueness violations, across adapters. Matched on the exception's message
      # as well as its class, because the useful information — WHICH field collided
      # — only exists in the message.
      UNIQUENESS_PATTERN = /
        has\s+already\s+been\s+taken |
        duplicate\s+key\s+value |
        UNIQUE\s+constraint\s+failed |
        Duplicate\s+entry
      /xi

      attr_reader :seeded, :failures, :warnings

      def initialize(config: Loadwright.configuration, lifecycle: nil, guard: nil, stdout: $stdout)
        @config = config
        @lifecycle = lifecycle
        @guard = guard
        @stdout = stdout
        @seeded = []
        @failures = []
        @warnings = []
        @created_ids = {}
        @models = {}
        @cleanup_hook = nil
        @cleaned = false
      end

      # Loads the host app's factory definitions. Deliberately the host's, not ours:
      # the whole premise is that the app already knows how to build valid records.
      def load_factories!
        return self unless @config.factory_bot_enabled

        unless defined?(::FactoryBot)
          begin
            require "factory_bot"
          rescue LoadError
            raise SeedingError,
                  "factory_bot_enabled is true but factory_bot is not available. Add it to the " \
                  ":development, :test group, or set config.factory_bot_enabled = false to run " \
                  "without seeding (endpoints returning empty collections will be reported " \
                  "inconclusive, not healthy)."
          end
        end

        # FactoryBot::Registry is Enumerable but does not respond to #empty?, and
        # calling find_definitions twice raises DuplicateDefinitionError — so this
        # loads only when the host has not already done it (a rails_helper usually
        # has).
        ::FactoryBot.find_definitions if ::FactoryBot.factories.count.zero?
        self
      end

      # Seeds every resource in factory_map to `scale_factor` records. Returns the
      # id map path-param resolution consumes: { "post" => [1, 2, 3] }.
      def seed!(scale_factor)
        return {} unless @config.factory_bot_enabled
        return {} if @config.factory_map.empty?

        load_factories!
        register_cleanup

        @config.factory_map.each do |resource, spec|
          seed_resource(resource.to_s, normalize(spec), scale_factor)
        end

        created_ids
      end

      # { "post" => [ids] }, for PathParamResolver.
      def created_ids
        @created_ids.transform_values { |ids| ids.dup }
      end

      def total_created = @created_ids.values.sum(&:length)

      # ------------------------------------------------------------------- cleanup

      def cleanup!
        return self if @cleaned

        @cleaned = true

        case @config.seed_cleanup_strategy
        when :leave
          @stdout.puts "loadwright: leaving #{total_created} seeded row(s) in place " \
                       "(seed_cleanup_strategy = :leave)"
        when :transactional_rollback
          # The transaction is opened and rolled back by the caller that owns it;
          # there is nothing row-level to undo here. Selecting this under :http is a
          # config error caught at startup by Configuration#validate!.
          @stdout.puts "loadwright: seeded rows will disappear with the harness transaction"
        else
          delete_created_rows!
        end

        self
      end

      def to_h
        {
          strategy: @config.seed_cleanup_strategy,
          created: @created_ids.transform_values(&:length),
          total_created: total_created,
          failures: @failures.map(&:to_h),
          warnings: @warnings,
          cleaned_up: @cleaned
        }
      end

      private

      def normalize(spec)
        case spec
        when Symbol, String then { factory: spec.to_sym }
        when Hash then spec.transform_keys(&:to_sym)
        else raise SeedingError, "unusable factory_map entry: #{spec.inspect}"
        end
      end

      def seed_resource(resource, spec, scale_factor)
        factory = spec.fetch(:factory) { resource.to_sym }
        traits = Array(spec[:trait] || spec[:traits])
        attributes = spec[:attributes] || {}
        target = spec[:count] || scale_factor

        created = 0
        remaining = target

        # A watermark taken BEFORE any row exists, because a batch that raises
        # part-way through has already committed the rows it managed to create and
        # create_list returns nothing for them. Without this they are ours, untracked,
        # and left behind by cleanup — litter in a developer's database from a tool
        # whose main promise is that it does not leave any. Still strictly id-bounded;
        # nothing here widens into a truncate.
        model = model_for_factory(factory)
        @models[resource] = model if model
        watermark = max_id(model)

        while remaining.positive?
          batch = [remaining, @config.seed_batch_size].min

          begin
            records = create_batch(factory, batch, traits, attributes)
          rescue StandardError => e
            adopt_orphans(resource, model, watermark)
            record_failure(resource, factory, target, created, e)
            return
          end

          track(resource, records)
          created += records.length
          remaining -= batch

          # A health check between batches rather than one giant transaction: this
          # is where seeding itself can lock the table or exhaust the pool.
          break unless guard_allows_more?(resource, created, target)
        end

        @seeded << Seeded.new(
          resource: resource, factory: factory, requested: target,
          created: created, ids: @created_ids.fetch(resource, []).dup,
          model: model_for(resource)
        )
      end

      def create_batch(factory, count, traits, attributes)
        ::FactoryBot.create_list(factory, count, *traits, **attributes)
      end

      def track(resource, records)
        ids = records.filter_map { |record| record.id if record.respond_to?(:id) }
        (@created_ids[resource] ||= []).concat(ids)

        records.each { |record| @models[resource] ||= record.class }
      end

      def model_for(resource) = @models[resource]

      def model_for_factory(factory)
        return nil unless defined?(::FactoryBot)

        ::FactoryBot.factories.find(factory).build_class
      rescue StandardError
        # An unregistered factory surfaces properly when create_list is called; not
        # being able to pre-resolve the class only costs the orphan sweep.
        nil
      end

      def max_id(model)
        return nil if model.nil? || !model.respond_to?(:maximum)

        model.maximum(:id) || 0
      rescue StandardError
        nil
      end

      # Rows committed by a batch that then raised. Bounded by the watermark, so a
      # row that existed before the run can never be caught by this.
      def adopt_orphans(resource, model, watermark)
        return if model.nil? || watermark.nil?

        orphan_ids = model.where(model.arel_table[:id].gt(watermark)).pluck(:id) -
                     @created_ids.fetch(resource, [])
        return if orphan_ids.empty?

        (@created_ids[resource] ||= []).concat(orphan_ids)
        @warnings << "#{orphan_ids.length} #{resource} row(s) were committed by the batch that failed; " \
                     "they are tracked for cleanup"
      rescue StandardError => e
        @warnings << "could not track rows left behind by the failed #{resource} batch " \
                     "(#{e.class}); they may remain in the database"
      end

      # ---------------------------------------------------------------- collisions

      def record_failure(resource, factory, requested, created, error)
        if UNIQUENESS_PATTERN.match?(error.message)
          field = extract_field(error.message)
          remedy = if field
                     "add a sequence to the #{factory.inspect} factory:\n" \
                       "  factory :#{factory} do\n" \
                       "    sequence(:#{field}) { |n| \"#{field}-\#{n}\" }\n" \
                       "  end"
                   else
                     "add a sequence to the uniquely-constrained field on the #{factory.inspect} factory"
                   end

          failure = Failure.new(
            resource: resource, factory: factory, requested: requested, created: created,
            reason: "uniqueness collision: #{error.message}", remedy: remedy
          )
        else
          failure = Failure.new(
            resource: resource, factory: factory, requested: requested, created: created,
            reason: "#{error.class}: #{error.message}",
            remedy: "check that FactoryBot.create(#{factory.inspect}) works on its own"
          )
        end

        @failures << failure
        announce(failure)
      end

      # "Name has already been taken" -> "name"; Postgres/MySQL/SQLite index names
      # -> the column. Best-effort by design: a wrong guess costs a slightly less
      # specific message, while not guessing costs the user the actual fix.
      def extract_field(message)
        if (match = message.match(/Validation failed:\s*([A-Za-z_ ]+?)\s+has already been taken/i))
          return match[1].strip.downcase.tr(" ", "_")
        end

        message[/index_\w+_on_(\w+)/, 1] ||
          message[/Key\s+\((\w+)\)=/i, 1] ||
          message[/UNIQUE constraint failed:\s*\w+\.(\w+)/i, 1] ||
          message[/for key '\w+\.(\w+)'/i, 1]
      end

      def announce(failure)
        @stdout.puts <<~MSG
          loadwright: SEEDING FAILED for #{failure.resource} (factory #{failure.factory.inspect})
            created #{failure.created} of #{failure.requested} before failing
            #{failure.reason}

          #{failure.remedy}

          Loadwright will not work around this by generating values itself — that would produce data
          that does not match how your app is actually used. This resource is skipped; endpoints that
          depend on it will be reported inconclusive rather than healthy.
        MSG
      end

      # --------------------------------------------------------------- integration

      def guard_allows_more?(resource, created, target)
        return true unless @guard

        outcome = @guard.check_seeding_batch!(resource: resource, created: created, target: target)
        return true unless outcome == :stop

        @warnings << "seeding #{resource} stopped at #{created} of #{target} rows: the contention " \
                     "guard asked for less load"
        false
      rescue StandardError => e
        @warnings << "contention guard errored during seeding (#{e.class}); continuing without it"
        true
      end

      def register_cleanup
        return if @cleanup_hook

        # Registered with Lifecycle, not left to an `ensure`: ensure blocks do not
        # run on signals, and Ctrl-C partway through a 200k-row seed is exactly the
        # state a user will interrupt from.
        @cleanup_hook = @lifecycle&.register("seeded rows", critical: true) { cleanup! }
      end

      def delete_created_rows!
        return if @created_ids.empty?

        with_cleanup_timeout do
          # Reverse insertion order so children go before parents and a foreign key
          # cannot block the delete.
          @created_ids.keys.reverse_each do |resource|
            ids = @created_ids[resource]
            next if ids.empty?

            model = model_for(resource)
            next @warnings << "cannot clean up #{resource}: model class unknown" if model.nil?

            deleted = delete_in_batches(model, ids)
            @stdout.puts "loadwright: deleted #{deleted} seeded #{resource} row(s)"
          end
        end
      end

      def delete_in_batches(model, ids)
        deleted = 0
        ids.each_slice(500) do |slice|
          # delete_all on an explicit id list. NEVER truncate, and never a bare
          # delete_all on the model.
          deleted += model.where(id: slice).delete_all
        end
        deleted
      rescue StandardError => e
        @warnings << "cleanup of #{model} failed: #{e.class}: #{e.message}"
        deleted
      end

      # A cleanup that hangs holding locks is worse than the test that preceded it.
      def with_cleanup_timeout
        return yield unless defined?(::ActiveRecord::Base)

        adapter = ::ActiveRecord::Base.connection.adapter_name.to_s.downcase
        if adapter.include?("postgres")
          ::ActiveRecord::Base.connection.execute("SET lock_timeout = #{Integer(@config.lock_timeout_ms)}")
        elsif adapter.include?("mysql")
          ::ActiveRecord::Base.connection.execute(
            "SET SESSION innodb_lock_wait_timeout = #{(Integer(@config.lock_timeout_ms) / 1000.0).ceil}"
          )
        end

        yield
      rescue StandardError => e
        @warnings << "could not set a cleanup lock timeout (#{e.class}); cleaning up anyway"
        yield
      end
    end
  end
end
