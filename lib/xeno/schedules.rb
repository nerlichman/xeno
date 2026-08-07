require "yaml"

module Xeno
  # Compiles agent/schedules/*.md into Solid Queue recurring entries —
  # compile-to-the-queue's-native-scheduler, not a dispatcher. No polling
  # dispatcher: the queue's own recurring machinery fires ScheduleJob.
  #
  # Only keys under the managed prefix are touched; hand-written recurring
  # entries survive a sync. Dev servers never fire user schedules on
  # cadence — those are written for every environment section EXCEPT
  # development, where the dispatch endpoint triggers by name. The REAPER
  # entry is different: it's runtime infrastructure (turns with no live
  # owner), so it goes into every section including development.
  module Schedules
    MANAGED_PREFIX = "xeno_".freeze
    REAPER_KEY = "#{MANAGED_PREFIX}runtime_reaper".freeze

    module_function

    def sync!(definition: Xeno.definition, path: Rails.root.join("config", "recurring.yml"))
      existing = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      environments = (existing.keys.presence || %w[production]) | %w[development]

      environments.each do |env|
        section = (existing[env] ||= {})
        section.delete_if { |key, _| key.start_with?(MANAGED_PREFIX) }

        unless env == "development"
          definition.schedules.each do |name, schedule|
            section["#{MANAGED_PREFIX}#{name}"] = {
              "class" => "Xeno::ScheduleJob",
              "args" => [ name ],
              "schedule" => schedule.cron
            }
          end
        end

        section[REAPER_KEY] = reaper_entry
      end

      File.write(path, YAML.dump(existing))
      existing
    end

    def reaper_entry
      { "class" => "Xeno::ReaperJob", "schedule" => "every minute" }
    end
  end
end
