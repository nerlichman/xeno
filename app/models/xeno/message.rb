module Xeno
  class Message < ApplicationRecord
    acts_as_message chat_class: "Xeno::Chat"
  end
end
