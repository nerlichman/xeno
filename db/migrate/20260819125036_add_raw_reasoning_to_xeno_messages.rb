class AddRawReasoningToXenoMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :xeno_messages, :raw_reasoning, :json
  end
end
