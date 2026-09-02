# frozen_string_literal: true

require "json"
require "time"
require "loadwright/errors"
require "loadwright/discovery/endpoint"
require "loadwright/discovery/route_recognizer"
require "loadwright/history/redactor"

module Loadwright
  module Discovery
    # Endpoints from the app's own request specs — by RECORDING the requests they
    # make, not by parsing the files.
    #
    # WHY RECORDING AND NOT PARSING. A static parser looking for `get "/foo"` in
    # arbitrary RSpec files is coupled to how each team happens to write specs.
    # Shared examples, helper methods, request builders, and let-defined paths all
    # defeat it, and it fails by SILENTLY UNDER-DISCOVERING — which is the worst
    # failure shape available here, because the endpoints it missed get reported as
    # absent rather than skipped. Recording instead uses requests the team has
    # already demonstrated are valid, complex nested params included.
    #
    # (If a future change finds itself walking RSpec ASTs, that is the signal to
    # stop and reread this comment.)
    #
    # Two halves:
    #
    #   Recorder — prepended into ActionDispatch::Integration::Session so every
    #     request a spec makes is captured without changing its behaviour. Writes
    #     to a JSON file, redacted on the way in.
    #
    #   IntegrationSpecSource — reads that file and produces Endpoints, so
    #     `loadwright run` does not have to re-run anybody's suite.
    class IntegrationSpecSource
      FORMAT_VERSION = 1
      DEFAULT_FILENAME = "recorded-requests.json"

      # Enough to see the shape of what was missed without turning a warning into a
      # log dump. The count is always exact; this bounds only the examples.
      UNRECOGNISED_SAMPLE_LIMIT = 10

      # Prepended into the integration session. `#process` is the single funnel every
      # one of get/post/put/patch/delete/head goes through, so one hook captures all
      # of them — and hooking the funnel rather than each verb means a Rails version
      # that adds a verb is covered automatically.
      module Recorder
        class << self
          attr_accessor :sink

          def recording? = !sink.nil?

          def record(verb, path, session)
            return unless recording?

            sink.call(verb: verb, path: path, session: session)
          end
        end

        def process(method, path, **kwargs)
          result = super
          Recorder.record(method, path, self)
          result
        rescue StandardError
          # A spec that raised still tells us the endpoint exists and what a request
          # to it looks like. Recording it and letting the exception continue is
          # strictly more informative than losing it.
          Recorder.record(method, path, self)
          raise
        end
      end

      attr_reader :warnings

      def initialize(config: Loadwright.configuration, recognizer: nil, redactor: nil, stdout: $stdout)
        @config = config
        @recognizer = recognizer || RouteRecognizer.new
        @redactor = redactor || History::Redactor.new(config: config)
        @stdout = stdout
        @warnings = []
        @captured = []
      end

      # ------------------------------------------------------------------ recording

      # Installs the hook, yields (the caller runs the specs), then writes the file.
      def record!(output_path: default_output_path)
        install!
        yield self
        write!(output_path)
      ensure
        uninstall!
      end

      def install!
        require "action_controller"
        require "action_dispatch"
        require "action_dispatch/testing/integration"

        unless ::ActionDispatch::Integration::Session.ancestors.include?(Recorder)
          ::ActionDispatch::Integration::Session.prepend(Recorder)
        end

        Recorder.sink = method(:capture)
        self
      end

      def uninstall!
        Recorder.sink = nil
        self
      end

      def captured_count = @captured.length

      def write!(output_path = default_output_path)
        require "fileutils"

        # AN EMPTY CAPTURE DOES NOT OVERWRITE A GOOD RECORDING, and the message that
        # follows it says nothing was written -- which used to be the opposite of what
        # happened. Pointing `record` at a narrower spec path to investigate something,
        # capturing nothing, and finding the previous recording replaced by an empty
        # one is an ordinary way to work; the next command then refuses with "0
        # endpoints", several steps removed from the cause. The message was written to
        # reassure at exactly the moment it should have warned.
        #
        # Recording is the slowest step in the workflow. Replacing a good one with
        # nothing is a bad trade for a capture that produced nothing, and refusing the
        # write is what makes the existing message true.
        if @captured.empty? && File.file?(output_path)
          # NAMES WHAT SURVIVED, not just what did not happen. "Nothing was written" is
          # true and still leaves someone who has been bitten once going to check the
          # file. The count is already in hand.
          kept = existing_request_count(output_path)
          @warnings << "captured no requests, so #{output_path} was left as it was" \
                       "#{kept ? " -- its #{kept} recorded request(s) are intact" : ''}"
          return output_path
        end

        FileUtils.mkdir_p(File.dirname(output_path))

        # A mounted Rack app (Grape, Sinatra, Roda) is ONE Rails route, so recognition
        # answered the mount point for every request inside it. Recovered here, once,
        # with every recording available rather than one at a time.
        requests = MountedPathTemplate.apply(@captured)
        report_inferred(requests)

        # WHICH DATABASE THESE IDS CAME FROM. `record` runs specs against test;
        # `run` measures development. That is the documented two-command workflow, so
        # recorded ids are routinely ids that do not exist in the database being
        # measured -- and every request 404s.
        #
        # SAMPLED AT CAPTURE TIME, NOT HERE. This method runs in the CLI process,
        # which booted before the specs did and stays in whatever environment it was
        # invoked with. The specs then connect to test -- and asking here answered
        # "development" for a recording made entirely of test ids, so the guard below
        # compared "development" to "development", passed, and dropped nothing. The
        # mechanism was present and the value was wrong, which is worse than no
        # mechanism at all: it reports all clear.
        payload = {
          "version" => FORMAT_VERSION,
          "recorded_at" => Time.now.utc.iso8601,
          "unrecognised_count" => @unrecognised.to_i,
          # WHICH ones, not just how many. A count alone tells a reader that coverage
          # was lost and nothing about where, and those endpoints are the one class of
          # "could not measure" that gets no row of its own in the report.
          "unrecognised_samples" => Array(@unrecognised_samples),
          "requests" => requests
        }.merge(@data_source || data_source)
        File.write(output_path, JSON.pretty_generate(payload))
        output_path
      end

      # ------------------------------------------------------------------- reading

      def endpoints(input_path: default_output_path)
        recordings = read(input_path)
        return [] if recordings.empty?

        grouped = recordings.group_by { |r| [r["template"], r["verb"].to_s.downcase.to_sym] }

        grouped.map { |(template, verb), group| build_endpoint(template, verb, group) }
      end

      def existing_request_count(path)
        Array(JSON.parse(File.read(path))["requests"]).length
      rescue StandardError
        nil
      end

      def default_output_path
        File.join(@config.report_output_dir.to_s, DEFAULT_FILENAME)
      end

      private

      # RECORDED IDS ARE DROPPED when the recording came from a different database.
      # They are ids that demonstrably worked -- in `test`, which is where `record`
      # runs its specs, while `run` measures `development`. Keeping them means every
      # request 404s and the endpoint is reported as broken. The parameter stays
      # DECLARED, so it resolves from an override or a seeded record, or is honestly
      # reported unresolvable.
      def warn_about_environment_mismatch(payload, input_path)
        difference = source_difference(payload)
        return if difference.nil?

        @warnings << "#{input_path} #{difference}, so its recorded ids almost certainly do not exist " \
                     "here. They are ignored; path parameters resolve from path_param_overrides or from " \
                     "seeded records instead."
        @stdout.puts "loadwright: #{@warnings.last}"
        @ignore_recorded_values = true
      end

      # THE DATABASE NAME IS ASKED FIRST, and the environment name is the fallback.
      #
      # The environment name is a PROXY for the question that actually matters -- did
      # these ids come from the database this run is about to measure -- and it is a
      # proxy that goes wrong in exactly the workflow the docs recommend. `record`
      # boots the app in one environment and then runs specs that connect to another;
      # `Rails.env` never moves, while the connection does. Comparing what the two
      # processes were CONNECTED TO answers the real question directly.
      #
      # Returns a phrase describing the difference, or nil when there is none to
      # describe. nil also covers "cannot tell": an older recording carries neither
      # field, and inventing a mismatch from a missing value would drop ids that are
      # very probably fine.
      def source_difference(payload)
        recorded_db = payload["database"].to_s
        current_db = current_database.to_s
        unless recorded_db.empty? || current_db.empty?
          return nil if recorded_db == current_db

          return "was recorded against the #{recorded_db} database and this run measures #{current_db}"
        end

        recorded_env = payload["environment"].to_s
        return nil if recorded_env.empty? || recorded_env == "unknown"
        return nil if recorded_env == current_environment

        "was recorded in #{recorded_env} and this run targets #{current_environment}"
      end

      # Sampled where the request was actually issued. Kept as one hash so a recording
      # carries a single coherent answer rather than two fields written at two moments.
      def data_source
        { "environment" => current_environment, "database" => current_database }.compact
      end

      def current_environment
        return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env)

        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "unknown"
      rescue StandardError
        "unknown"
      end

      # The name of the database the CURRENT connection is pointed at. Nil rather than
      # a guess when there is no connection to ask -- an absent answer falls back to
      # the environment name, while a wrong one would silently discard good ids.
      def current_database
        return nil unless defined?(::ActiveRecord::Base)

        name = ::ActiveRecord::Base.connection_db_config.database.to_s
        name.empty? ? nil : name
      rescue StandardError
        nil
      end

      def report_inferred(requests)
        inferred = requests.select { |request| request["inferred_template"] }
        return if inferred.empty?

        @stdout.puts "loadwright: #{inferred.length} request(s) were behind a mounted Rack app, " \
                     "whose routes Rails reports as a single mount point. Templates were inferred " \
                     "from the recorded paths:"
        inferred.map { |r| "#{r['verb'].upcase} #{r['template']}" }.uniq.sort.each do |line|
          @stdout.puts "  #{line}"
        end
      end

      def capture(verb:, path:, session:)
        request = session.request
        # Normalised HERE as well as inside the recognizer, so the path stored in the
        # recording, the samples printed for an unmapped request, and the path the
        # router was asked about are all the same string. A mounted app whose mount
        # point and sub-path each contribute a slash produces `//...`, which is a
        # protocol-relative URL to anything that parses it.
        path = RouteRecognizer.normalize_slashes(path)
        recognition = @recognizer.recognize(verb, path)

        # A path the router does not recognise is dropped, and the count reported.
        # Keeping the concrete path would manufacture one endpoint per id — 200
        # requests against 200 posts becoming 200 "endpoints" — which is a worse
        # outcome than a named gap.
        unless recognition
          @unrecognised = @unrecognised.to_i + 1
          @unrecognised_samples ||= []
          # Redacted like every other path that goes into the file: this one ends up
          # in the report, where an unmapped request is only useful if you can see
          # which request it was.
          if @unrecognised_samples.length < UNRECOGNISED_SAMPLE_LIMIT
            @unrecognised_samples << "#{verb.to_s.upcase} #{@redactor.path(path)}"
          end
          return
        end

        # The first request is where the specs' own connection is observable. Later
        # ones cannot change the answer without changing which database the ids came
        # from, which is a state no recording can represent honestly anyway.
        @data_source ||= data_source

        @captured << {
          "verb" => verb.to_s.downcase,
          "template" => recognition.template,
          "path" => @redactor.path(path),
          "path_values" => recognition.path_values.transform_keys(&:to_s),
          "controller" => recognition.controller,
          "action" => recognition.action,
          "query" => @redactor.params(safe_query(request)),
          "body" => @redactor.body(safe_body(session)),
          "headers" => @redactor.headers(loadwright_relevant_headers(request)),
          "status" => safe_status(session)
        }
      rescue StandardError => e
        @warnings << "could not record #{verb.to_s.upcase} #{path}: #{e.class}: #{e.message}"
      end

      def safe_query(request)
        request.respond_to?(:GET) ? request.GET : {}
      rescue StandardError
        {}
      end

      def safe_body(session)
        request = session.request
        return {} unless request.respond_to?(:POST)

        request.POST
      rescue StandardError
        {}
      end

      def safe_status(session)
        session.response&.status
      rescue StandardError
        nil
      end

      # Content negotiation and custom API headers only. Auth headers are redacted by
      # the redactor above, but the narrower filter here means a recording does not
      # carry the whole env either.
      def loadwright_relevant_headers(request)
        return {} unless request.respond_to?(:headers)

        request.headers.to_h.select { |key, _| key.is_a?(String) && key.start_with?("HTTP_", "CONTENT_") }
               .to_h { |key, value| [normalize_header(key), value] }
      rescue StandardError
        {}
      end

      def normalize_header(rack_key)
        rack_key.sub(/\AHTTP_/, "").split("_").map(&:capitalize).join("-")
      end

      def read(input_path)
        return [] unless File.file?(input_path)

        payload = JSON.parse(File.read(input_path))

        unless payload["version"] == FORMAT_VERSION
          raise DiscoveryError,
                "#{input_path} was written by a different version of Loadwright " \
                "(format #{payload['version'].inspect}, expected #{FORMAT_VERSION}). " \
                "Re-record with `loadwright record --specs <dir>`."
        end

        warn_about_environment_mismatch(payload, input_path)

        if payload["unrecognised_count"].to_i.positive?
          count = payload["unrecognised_count"].to_i
          samples = Array(payload["unrecognised_samples"])
          listed =
            if samples.empty?
              ""
            elsif samples.length < count
              ". The first #{samples.length}: #{samples.join(', ')}"
            else
              ": #{samples.join(', ')}"
            end

          @warnings << "#{count} recorded request(s) could not be mapped to a route template and were " \
                       "skipped; those endpoints are not covered by this run#{listed}"
        end

        Array(payload["requests"])
      rescue JSON::ParserError => e
        raise DiscoveryError, "#{input_path} is not readable JSON: #{e.message}. Re-record it."
      end

      # A REJECTION SPEC'S IDENTIFIER IS NOT EVIDENCE THAT A TEMPLATE IS EXERCISABLE.
      #
      # The comment below used to say these values were "demonstrably real because a
      # spec used them successfully" -- and the code took them from EVERY recording in
      # the group, including the ones asserting that the API rejects a bad request.
      # Those hardcode a deliberately-non-record identifier into the path, so the
      # recorder faithfully captured a value guaranteed to resolve to nothing, and the
      # endpoint then failed on every request of every cell, forever.
      #
      # The status was on disk the whole time. In one real recording of 600 requests,
      # 56 carried such a literal: NONE of them had returned 2xx, and none involved a
      # template substitution. Either signal identifies all of them with no false
      # positives, and status is the one that needs no knowledge of anybody's
      # placeholder vocabulary -- so it works for every app rather than for the one
      # whose naming habits somebody enumerated by hand.
      #
      # Two workarounds died here: excluding rejection spec files by name (which forces
      # a bad trade when one file carries both a rejection and a healthy case), and
      # listing the literals in excluded_paths (which is a property of one team's
      # naming and rots the moment somebody invents a new one).
      def successful?(recording)
        status = recording["status"]

        status.is_a?(Integer) && (200..299).cover?(status)
      end

      def build_endpoint(template, verb, group)
        # Concrete ids, one list per param — resolution order #2 for path params, and
        # taken ONLY from recordings that actually succeeded, which is what makes the
        # "demonstrably real" claim true rather than aspirational.
        successful = group.select { |recording| successful?(recording) }
        recorded_values = successful.each_with_object({}) do |recording, out|
          Array(recording["path_values"]).each do |name, value|
            (out[name.to_sym] ||= []) << value
          end
        end
        recorded_values.each_value(&:uniq!)
        # Keys kept, values dropped: the parameter stays declared so the template and
        # the parameter list cannot disagree, and resolution falls through to an
        # override or a seeded record.
        recorded_values.each_key { |key| recorded_values[key] = [] } if @ignore_recorded_values

        richest = group.max_by { |r| (r["body"] || {}).size + (r["query"] || {}).size }

        Endpoint.new(
          path: template,
          verb: verb,
          source: :integration_spec,
          path_params: recorded_values.keys,
          query_params: (richest["query"] || {}).map { |name, value| { name: name, example: value } },
          request_body: presence(richest["body"]),
          recorded_path_values: recorded_values,
          # Whether ANY recording of this template succeeded. When none did, the
          # template is real (a route recognised it) but no usable identifier was ever
          # captured -- and saying that is far more useful than replaying a literal
          # that cannot resolve and reporting the resulting 404 as the endpoint's.
          recorded_success: successful.any?,
          recorded_attempts: group.length,
          recorded_headers: richest["headers"] || {},
          expected_statuses: group.filter_map { |r| r["status"] }.uniq,
          description: [richest["controller"], richest["action"]].compact.join("#").then { |s| presence(s) }
        )
      end

      def presence(value) = value.nil? || value.empty? ? nil : value
    end
  end
end
