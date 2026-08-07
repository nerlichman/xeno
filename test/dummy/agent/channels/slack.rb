Xeno.channel :slack do
  signing_secret ENV.fetch("SLACK_SIGNING_SECRET", "dummy-signing-secret")
  bot_token ENV.fetch("SLACK_BOT_TOKEN", "xoxb-dummy")
  api_base ENV["FAKE_SLACK_URL"] if ENV["FAKE_SLACK_URL"]
end
