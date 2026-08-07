require "test_helper"

# ruby_llm 2aaddf96 owns the model registry: including ActsAs (which
# Xeno::Chat does) auto-wires model_registry_store to the library's own
# record class — the engine no longer configures anything. These assert the
# same behavior the old xeno.model_registry initializer existed for:
# refresh!/model resolution can never hit an unknown constant.
class ModelRegistryConfigTest < ActiveSupport::TestCase
  test "loading the chat class auto-wires the model registry store" do
    Xeno::Chat # ensure ActsAs inclusion ran
    assert_equal RubyLLM::ActiveRecord::Model, RubyLLM.config.model_registry_store
  end

  test "the wired store is usable (refresh! persistence target exists)" do
    store = RubyLLM.config.model_registry_store
    assert store.respond_to?(:read) && store.respond_to?(:write),
      "store must implement the registry persistence API (read/write)"
    assert store.table_exists?, "ruby_llm_models must exist for refresh! to persist"
  end
end
