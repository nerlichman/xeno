# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "generators/xeno/tool/tool_generator"

class ToolGeneratorTest < Rails::Generators::TestCase
  tests Xeno::Generators::ToolGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "creates a snake_case tool file with the namespaced constant" do
    run_generator [ "GetWeather" ]

    assert_file "agent/tools/get_weather.rb" do |content|
      assert_match(/class Xeno::Tools::GetWeather < Xeno::Tool/, content)
      assert_match(/approval :always/, content)
      assert_match(/def execute\(input:\)/, content)
    end
  end

  test "accepts snake_case input too" do
    run_generator [ "order_lookup" ]
    assert_file "agent/tools/order_lookup.rb", /class Xeno::Tools::OrderLookup < Xeno::Tool/
  end
end
