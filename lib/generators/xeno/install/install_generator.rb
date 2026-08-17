# frozen_string_literal: true

module Xeno
  module Generators
    # Mounted-mode install: initializer, engine mount, migrations, and the agent/ scaffold.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      class_option :skip_migrations, type: :boolean, default: false,
                                     desc: "Skip copying the engine migrations"

      def copy_initializer
        template "initializer.rb", "config/initializers/xeno.rb"
      end

      def mount_engine
        route 'mount Xeno::Engine => "/agent"'
      end

      def install_migrations
        rake "xeno:install:migrations" unless options[:skip_migrations]
      end

      def scaffold_agent
        template "agent.rb", "agent/agent.rb"
        template "instructions.md", "agent/instructions.md"
        create_file "agent/tools/.keep", ""
      end

      def show_next_steps
        say <<~NEXT

          xeno is installed. Next steps:

            1. bin/rails db:migrate
            2. Edit agent/instructions.md (the agent's always-on system prompt)
            3. bin/rails g xeno:tool GetWeather   # your first tool
            4. Set the auth check in config/initializers/xeno.rb — the HTTP
               channel is fail-closed and returns 401 until you do.
            5. bin/rails xeno:info                # see the resolved agent

          If coding agents work in this repo, add to your AGENTS.md/CLAUDE.md:

            The agent/ directory uses the xeno gem. Before changing it, read
            the gem's docs: `bundle show xeno`, then README.md and
            docs/runtime.md there. Never unpin the ruby_llm git ref.

        NEXT
      end
    end
  end
end
