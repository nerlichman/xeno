# frozen_string_literal: true

module Xeno
  class Engine < ::Rails::Engine
    isolate_namespace Xeno

    # agent/ is a Zeitwerk root namespaced under Xeno with per-slot submodules:
    # agent/tools/get_weather.rb defines Xeno::Tools::GetWeather. Non-constant files are xeno's to
    # load: agent.rb is a config DSL, schedules/ holds markdown, channels/ is a DSL slot, lib/ is
    # plain shared Ruby required by the author.
    initializer "xeno.agent_autoload", before: :setup_main_autoloader do |app|
      agent_root = Xeno.agent_root
      if agent_root&.directory?
        autoloader = Rails.autoloaders.main
        autoloader.push_dir(agent_root, namespace: Xeno)
        autoloader.ignore(agent_root.join("agent.rb"))
        autoloader.ignore(agent_root.join("instructions.rb"))
        %w[schedules channels hooks skills lib].each do |dir|
          autoloader.ignore(agent_root.join(dir))
        end
      end
    end

    # The cached definition holds tool classes; drop it whenever the app reloads so dev picks up
    # edits under agent/.
    config.to_prepare do
      Xeno.reset_definition!
    end
  end
end
