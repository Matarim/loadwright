# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Engine
    # Contention detection and the backoff ladder: pause and drain, step down
    # concurrency, quarantine the endpoint, cooldown, global abort.
    #
    # ABSOLUTE RULE: never terminate, cancel or kill a database session. Never
    # pg_terminate_backend, pg_cancel_backend, KILL, or UNLOCK TABLES. Under
    # contention the only correct action is to send the database less work.
    #
    # Specified in references/resource-contention.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class ResourceGuard
      def check!(*, **, &)
        raise NotImplementedError, "Loadwright::Engine::ResourceGuard#check! is not implemented yet"
      end

      def backoff!(*, **, &)
        raise NotImplementedError, "Loadwright::Engine::ResourceGuard#backoff! is not implemented yet"
      end

      def quarantine!(*, **, &)
        raise NotImplementedError, "Loadwright::Engine::ResourceGuard#quarantine! is not implemented yet"
      end
    end
  end
end
