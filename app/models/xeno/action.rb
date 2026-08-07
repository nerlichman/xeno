module Xeno
  # One requested tool call: the durability checkpoint and (in M4) the
  # approval state. A completed action means "executed AND its result is in
  # the transcript" — the two are committed in one transaction, so replay
  # logic can trust either signal.
  class Action < ApplicationRecord
    STATUSES = %w[pending pending_approval approved denied completed failed].freeze
    KINDS = %w[tool question].freeze

    belongs_to :turn, class_name: "Xeno::Turn"

    validates :status, inclusion: { in: STATUSES }
    validates :kind, inclusion: { in: KINDS }

    def self.record!(turn, tool_call, kind: "tool")
      find_or_create_by!(turn: turn, tool_call_id: tool_call.id) do |action|
        action.tool_name = tool_call.name
        action.kind = kind
        action.input = tool_call.arguments
      end
    end

    def completed? = status == "completed"
    def awaiting_input? = %w[pending_approval].include?(status)
  end
end
