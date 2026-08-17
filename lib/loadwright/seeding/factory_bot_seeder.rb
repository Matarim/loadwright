# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Seeding
    # Populates via the host app's own factories at each scale factor, in batches
    # with a health check between them. On a uniqueness collision it names the
    # factory and field and stops — it never invents values to route around a
    # missing sequence. Cleanup deletes only tracked ids and NEVER truncates.
    #
    # Specified in references/discovery-and-load-engine.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class FactoryBotSeeder
      def seed!(*, **, &)
        raise NotImplementedError, "Loadwright::Seeding::FactoryBotSeeder#seed! is not implemented yet"
      end

      def cleanup!(*, **, &)
        raise NotImplementedError, "Loadwright::Seeding::FactoryBotSeeder#cleanup! is not implemented yet"
      end
    end
  end
end
