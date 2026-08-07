class Xeno::Tools::ChargeCard < Xeno::Tool
  description "Charge the customer's card on file. Irreversible."
  parameter :amount_cents, type: :integer, description: "Amount to charge in cents"

  approval :always

  def execute(amount_cents:)
    if (log = ENV["CHARGE_LOG"])
      File.open(log, "a") { |f| f.puts("charged #{amount_cents}") }
    end
    { status: "succeeded", charge_id: "ch_#{amount_cents}", amount_cents: amount_cents }
  end
end
