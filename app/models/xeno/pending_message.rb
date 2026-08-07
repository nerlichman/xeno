module Xeno
  # Messages that arrived while a turn was running. Drained into the next
  # turn when the session parks or the turn completes.
  class PendingMessage < ApplicationRecord
    belongs_to :session, class_name: "Xeno::Session"
  end
end
