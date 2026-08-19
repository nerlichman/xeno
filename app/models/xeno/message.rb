# frozen_string_literal: true

module Xeno
  class Message < ApplicationRecord
    acts_as_message chat_class: "Xeno::Chat"

    # Identity, the owning chat, and the text itself are all a repurposed row keeps. Every other
    # column described the utterance the row used to be, so it resets to its schema default —
    # which means a column added to the message table later is cleared without anyone having to
    # remember this code exists. A xeno-owned column meant to survive a repurpose must be named here.
    REPURPOSE_KEEPS = %w[id chat_id role content created_at updated_at].freeze

    # Rewrites this row as +content+ under +role+, discarding everything that described the
    # utterance it used to be. Compaction repurposes the earliest compacted row into its summary.
    def repurpose!(role:, content:)
      update!(reset_attributes.merge(role: role, content: content))
    end

    private

    def reset_attributes
      (self.class.column_names - REPURPOSE_KEEPS).to_h do |name|
        [ name, self.class.column_defaults[name] ]
      end
    end
  end
end
