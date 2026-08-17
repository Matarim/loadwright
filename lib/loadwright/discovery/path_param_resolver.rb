# frozen_string_literal: true

require "loadwright/errors"

module Loadwright
  module Discovery
    # Resolves {id} to a real record: seeded ids, then recorded ids, then
    # path_param_overrides, then the OpenAPI example last. Unresolvable means skip
    # the endpoint and name the param — never send a placeholder and report the 404
    # as a performance result. Rotates ids so one hot row does not distort cache and
    # lock behaviour.
    #
    # Specified in references/discovery-and-load-engine.md
    #
    # STATUS: stub. Implemented in a later session per CLAUDE.md section 4.
    class PathParamResolver
      def resolve(*, **, &)
        raise NotImplementedError, "Loadwright::Discovery::PathParamResolver#resolve is not implemented yet"
      end
    end
  end
end
