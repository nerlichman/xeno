# frozen_string_literal: true

module Xeno
  # What an approval lambda gets to look at.
  ApprovalContext = Struct.new(:session, :turn, :tool_name, :arguments, :principal, keyword_init: true)
end
