# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
# Bring the dummy app's test database up to date with the engine's migrations
# (before rails/test_help, whose pending-migration check would abort).
ActiveRecord::MigrationContext.new(ActiveRecord::Migrator.migrations_paths).migrate

require "rails/test_help"

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end

module FakeLLMHelpers
  # Boot a FakeLLM scripted by the block and point RubyLLM's Ollama api base at it.
  # Stopped automatically in teardown.
  def start_fake_llm(&script)
    fake = FakeLLM.new(&script).start
    (@fake_llms ||= []) << fake
    RubyLLM.configure { |c| c.ollama_api_base = fake.url }
    fake
  end

  # A chat wired to the fake server. Mirrors the spike harness.
  def fake_chat(model: "fake-model", **options)
    RubyLLM.chat(model: model, provider: :ollama, assume_model_exists: true, **options)
  end
end

class ActiveSupport::TestCase
  include FakeLLMHelpers

  teardown do
    @fake_llms&.each(&:stop)
    @fake_llms = nil
  end
end
