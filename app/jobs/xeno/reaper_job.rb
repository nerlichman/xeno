module Xeno
  # Periodic sweep for turns with no live owner (see Xeno::Reaper). Fired
  # by Solid Queue's recurring machinery, a cron hitting `xeno:reap`, or
  # any other scheduler — running it twice is harmless.
  class ReaperJob < ApplicationJob
    queue_as :default

    def perform
      Reaper.sweep!
    end
  end
end
