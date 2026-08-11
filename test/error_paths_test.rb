# frozen_string_literal: true

require "test_helper"

# Hardening: API error paths respond with structured JSON, never 500s.
class ErrorPathsTest < ActionDispatch::IntegrationTest
  setup do
    Xeno.config.authenticate = ->(_r) { { "user" => "t" } }
  end

  teardown do
    Xeno.config.authenticate = nil
  end

  AUTH = {}.freeze

  test "unknown session is 404 with a JSON body, on every endpoint" do
    post "/agent/v1/sessions/999999/messages", params: { message: "x", continuation_token: "y" }, as: :json
    assert_response :not_found
    assert JSON.parse(response.body)["error"]

    post "/agent/v1/sessions/999999/cancel"
    assert_response :not_found

    get "/agent/v1/sessions/999999/stream"
    assert_response :not_found
  end

  test "missing required params are 400, not 500" do
    post "/agent/v1/sessions", params: {}, as: :json
    assert_response :bad_request
    assert_match(/message/, JSON.parse(response.body)["error"])
  end

  test "unknown action on inputs is 404" do
    start_fake_llm
    session = Xeno::Session.open!(message: "hi", definition: TestDefinition.new)

    post "/agent/v1/sessions/#{session.id}/inputs",
      params: { action_id: 424_242, decision: "approve" }, as: :json
    assert_response :not_found
  end
end
