# frozen_string_literal: true

module Xeno
  module Generators
    # rails g xeno:tool GetWeather → agent/tools/get_weather.rb (the path supplies the runtime name:
    # get_weather)
    class ToolGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      def create_tool
        template "tool.rb.tt", "agent/tools/#{file_name}.rb"
      end
    end
  end
end
