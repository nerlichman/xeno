class Xeno::Tools::ChargeCard < Xeno::Tool
  description "Charge the customer's card. Irreversible."
  parameter :amount_cents, type: :integer, description: "Amount to charge, in cents"

  approval :always

  def execute(amount_cents:)
    File.open("charges.log", "a") { |f| f.puts "charged #{amount_cents}" }
    { status: "succeeded", charge_id: "ch_#{amount_cents}" }
  end
end

