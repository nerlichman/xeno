# Standalone mode: Rails as an implementation detail. A scaffolded app is
# four visible files (agent/, Gemfile, config.ru, .gitignore); the entire
# Rails::Application lives HERE, inside the gem — the same trick Nitro's
# config plays inside the eve package.
#
#   # config.ru
#   require "xeno/standalone"
#   run Xeno.rails_app
#
# SQLite + Solid Queue inside Puma (`xeno server`) make it one process with
# zero external services; migrations run at boot.
require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"

# A config.ru-only app has no Bundler.require(*Rails.groups); pull in what
# the scaffolded Gemfile provides.
require "solid_queue"
require "sqlite3"

require "xeno"
require "xeno/schedules"
require "xeno/standalone/local_secret"
require "xeno/standalone/model_refresh"
require "yaml"

module Xeno
  class StandaloneApplication < Rails::Application
    APP_ROOT = Pathname(Dir.pwd)

    config.root = APP_ROOT
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = ENV["RAILS_ENV"] == "production"
    config.consider_all_requests_local = ENV["RAILS_ENV"] != "production"
    config.api_only = false
    config.logger = ActiveSupport::TaggedLogging.logger($stdout)
    config.log_level = ENV.fetch("LOG_LEVEL", "info")

    config.active_record.dump_schema_after_migration = false
    config.active_job.queue_adapter = :solid_queue

    # One durable file under storage/ for everything: app rows + queue.
    config.paths["db/migrate"] = [ Xeno::Engine.root.join("db", "migrate").to_s ]

    def config.database_configuration
      {
        Rails.env => {
          "primary" => {
            "adapter" => "sqlite3",
            "database" => ENV.fetch("XENO_DATABASE", "storage/xeno_#{Rails.env}.sqlite3"),
            "pool" => ENV.fetch("RAILS_MAX_THREADS", 10).to_i,
            # Busy handler: web + Solid Queue's forked dispatcher/worker share this
            # one file; without a timeout the sqlite3 adapter does NOT wait for
            # locks ("default: no wait") and every collision raises
            # SQLite3::BusyException. Same 5s default rails new generates.
            "timeout" => ENV.fetch("XENO_DATABASE_TIMEOUT", 5000).to_i
          }
        }
      }
    end

    config.secret_key_base = ENV["SECRET_KEY_BASE"] || Xeno::Standalone.local_secret(APP_ROOT)
  end

  module Standalone
    module_function

    # Boot: initialize the app, then bring the database up to date — the
    # engine's migrations plus Solid Queue's tables (loaded straight from
    # the solid_queue gem's install template).
    def boot!
      ENV["RAILS_ENV"] ||= "development"
      FileUtils.mkdir_p(StandaloneApplication::APP_ROOT.join("storage"))

      app = Rails.application || StandaloneApplication.instance
      unless app.initialized?
        app.initialize!
        app.routes.draw do
          mount Xeno::Engine => "/agent"
          root to: redirect("/agent/dev")
        end
      end

      migrate!
      refresh_models!
      write_recurring_config!
      Rails.application
    end

    # Solid Queue's recurring machinery is how the reaper (always) and the
    # compiled schedules (outside development) fire in standalone mode. The
    # file lives under storage/ (gitignored) so the scaffold stays four
    # visible files; the env var — read by Solid Queue's supervisor, which
    # starts after config.ru has loaded — points the scheduler at it.
    def write_recurring_config!
      section = { Xeno::Schedules::REAPER_KEY => Xeno::Schedules.reaper_entry }
      unless Rails.env.development?
        Xeno.definition.schedules.each do |name, schedule|
          section["#{Xeno::Schedules::MANAGED_PREFIX}#{name}"] = {
            "class" => "Xeno::ScheduleJob", "args" => [ name ], "schedule" => schedule.cron
          }
        end
      end

      path = StandaloneApplication::APP_ROOT.join("storage", "recurring.yml")
      File.write(path, YAML.dump({ Rails.env.to_s => section }))
      ENV["SOLID_QUEUE_RECURRING_SCHEDULE"] ||= File.join("storage", "recurring.yml")
    end

    def migrate!
      ActiveRecord::MigrationContext.new([ Xeno::Engine.root.join("db", "migrate").to_s ]).migrate

      connection = ActiveRecord::Base.lease_connection
      unless connection.table_exists?("solid_queue_jobs")
        load queue_schema_path
      end
    end

    def queue_schema_path
      spec = Gem::Specification.find_by_name("solid_queue")
      File.join(spec.gem_dir, "lib", "generators", "solid_queue", "install", "templates", "db", "queue_schema.rb")
    end

    # The gem-owned puma config used by `xeno server` — Solid Queue runs
    # inside Puma (SOLID_QUEUE_IN_PUMA), one process total.
    def puma_config_path
      File.expand_path("standalone/puma.rb", __dir__)
    end
  end

  def self.rails_app
    Standalone.boot!
  end
end
