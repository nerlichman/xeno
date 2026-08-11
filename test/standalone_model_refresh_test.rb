# frozen_string_literal: true

require "test_helper"
require "xeno/standalone/model_refresh"

class StandaloneModelRefreshTest < ActiveSupport::TestCase
  setup do
    RubyLLM::ActiveRecord::Model.delete_all
  end

  test "first boot (empty registry) refreshes once" do
    calls = with_refresh_stub { Xeno::Standalone.refresh_models! }
    assert_equal 1, calls.size
  end

  test "a populated registry is never refreshed again" do
    RubyLLM::ActiveRecord::Model.create!(model_id: "m", name: "m", provider: "openai")
    calls = with_refresh_stub { Xeno::Standalone.refresh_models! }
    assert_equal 0, calls.size
  end

  test "XENO_SKIP_MODEL_REFRESH disables the refresh" do
    ENV["XENO_SKIP_MODEL_REFRESH"] = "1"
    calls = with_refresh_stub { Xeno::Standalone.refresh_models! }
    assert_equal 0, calls.size
  ensure
    ENV.delete("XENO_SKIP_MODEL_REFRESH")
  end

  test "a failing refresh never blocks boot" do
    with_refresh_stub(-> { raise "provider down" }) do
      assert_nothing_raised { Xeno::Standalone.refresh_models! }
    end
  end

  private

  def with_refresh_stub(body = nil)
    calls = []
    models = RubyLLM.models
    models.define_singleton_method(:refresh!) do |*args|
      calls << args
      body&.call
    end
    yield
    calls
  ensure
    models.singleton_class.remove_method(:refresh!)
  end
end
