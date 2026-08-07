module Xeno
  # The at-least-once dedup ledger. Redelivered work (a cron tick fired
  # twice, a Slack retry storm) claims its (scope, key) once; every other
  # delivery loses the unique-index race and can read what the winner
  # recorded in metadata.
  class Dedup < ApplicationRecord
    validates :scope, :key, presence: true

    # Returns the freshly claimed row, or nil when the key was already
    # claimed. Safe inside enclosing transactions (savepoint), safe under
    # concurrency (the unique index decides).
    def self.claim(scope, key, metadata: {})
      transaction(requires_new: true) do
        create!(scope: scope, key: key, metadata: metadata)
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def self.existing(scope, key)
      find_by(scope: scope, key: key)
    end
  end
end
