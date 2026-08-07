class Xeno::Tools::GetWeather < Xeno::Tool
  description "Return current weather for a city."
  parameter :city, description: "City name"

  def execute(city:)
    { city: city, condition: "Sunny", temp_f: 72 }
  end
end
