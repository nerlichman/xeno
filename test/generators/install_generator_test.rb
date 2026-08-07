require "test_helper"
require "rails/generators"
require "generators/xeno/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Xeno::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  setup do
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"),
      "Rails.application.routes.draw do\nend\n")
  end

  test "installs initializer, mount, and agent scaffold" do
    run_generator [ "--skip-migrations" ]

    assert_file "config/initializers/xeno.rb", /config\.authenticate/
    assert_file "config/routes.rb", %r{mount Xeno::Engine => "/agent"}
    assert_file "agent/agent.rb", /Xeno\.agent do/
    assert_file "agent/instructions.md", /always-on system prompt/
    assert_file "agent/tools/.keep"
  end
end
