# frozen_string_literal: true

require_relative "application"
require_relative "database"

SampleApp::Application.initialize!
SampleApp::Database.connect!
SampleApp::Database.load_schema!
