# Demo-only auth: a bearer key from the environment. Real apps configure
# this in config/initializers/xeno.rb (see the install generator's template).
if (key = ENV["XENO_DEMO_KEY"])
  Xeno.config.authenticate = ->(request) do
    token = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
    { "user" => "demo" } if ActiveSupport::SecurityUtils.secure_compare(token, key)
  end
end
