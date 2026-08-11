# frozen_string_literal: true

module Xeno
  # One requested tool call: the durability checkpoint and (in M4) the
  # approval state. A completed action means "executed AND its result is in
  # the transcript" — the two are committed in one transaction, so replay
  # logic can trust either signal.
  class Action < ApplicationRecord
    enum :status, %w[pending pending_approval approved denied completed failed].index_with(&:itself), validate: true
    enum :kind, %w[tool question].index_with(&:itself), prefix: true, validate: true

    belongs_to :turn, class_name: "Xeno::Turn"

    def self.record!(turn, tool_call, kind: "tool")
      find_or_create_by!(turn: turn, tool_call_id: tool_call.id) do |action|
        action.tool_name = tool_call.name
        action.kind = kind
        action.input = tool_call.arguments
      end
    end
  end
end
