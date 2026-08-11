# frozen_string_literal: true

require "test_helper"

# Phase-2 hardening regressions: the stale persisted-cancel flag (H), tool
# argument coercion (field finding), strict XENO_DEV_ROUTES (S5), the 0600
# standalone secret (S6), the loopback standalone bind (S4), and the dev-UI
# stylesheet 404 (field finding).
class CheapWinsTest < ActiveSupport::TestCase
  class Adder < Xeno::Tool
    description "Adds cents."
    parameter :amount_cents, type: :integer, description: "Amount in cents"
    parameter :double, type: :boolean, description: "Double it", required: false

    class << self
      attr_accessor :received
    end

    def execute(amount_cents:, double: false)
      self.class.received = { amount_cents: amount_cents, double: double }
      { total: double ? amount_cents * 2 : amount_cents }
    end
  end

  setup do
    Adder.received = nil
  end

  def start_session(definition)
    session = Xeno::Session.open!(message: "go", definition: definition)
    [ session, session.turns.order(:sequence).last ]
  end

  test "a stale persisted cancel does not poison the next turn (H)" do
    start_fake_llm
    definition = TestDefinition.new
    session, turn = start_session(definition)

    # A cancel that raced the previous turn's completion leaves the flag set.
    session.chat.cancel!
    assert session.chat.reload.cancelled?

    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run
    assert_equal "completed", turn.reload.status
    refute session.chat.reload.cancelled?, "the stale flag is cleared at turn start"
  end

  test "string-typed integers are coerced per the declared parameter type" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("added")
      else
        # llama in the field: integer parameter, String JSON value.
        FakeLLM.tool_call("adder", { amount_cents: "4200", double: "true" }, id: "call_coerce")
      end
    end
    definition = TestDefinition.new(tools: { "adder" => Adder })
    _session, turn = start_session(definition)

    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run
    assert_equal({ amount_cents: 4200, double: true }, Adder.received)
  end

  test "uncoercible arguments become a validation-error result, not an execution" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("sorry, fixed it")
      else
        FakeLLM.tool_call("adder", { amount_cents: "a lot" }, id: "call_uncoercible")
      end
    end
    definition = TestDefinition.new(tools: { "adder" => Adder })
    session, turn = start_session(definition)

    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run
    assert_nil Adder.received, "the tool must not execute with uncoercible arguments"

    action = turn.actions.sole
    assert_equal "failed", action.status
    assert_match(/invalid arguments/, action.output["content"])
    tool_row = session.chat.messages_association.where(role: "tool").sole
    assert_match(/expected integer/, tool_row.content)
  end

  test "XENO_DEV_ROUTES accepts only 1/true (S5)" do
    refute Xeno.dev_routes_enabled?, "test env with no var must be off"

    begin
      ENV["XENO_DEV_ROUTES"] = "0"
      refute Xeno.dev_routes_enabled?, '"0" must not enable dev routes'
      ENV["XENO_DEV_ROUTES"] = "yes"
      refute Xeno.dev_routes_enabled?
      ENV["XENO_DEV_ROUTES"] = "1"
      assert Xeno.dev_routes_enabled?
      ENV["XENO_DEV_ROUTES"] = "true"
      assert Xeno.dev_routes_enabled?
    ensure
      ENV.delete("XENO_DEV_ROUTES")
    end
  end

  test "standalone local secret is written 0600 and tightened on read (S6)" do
    require "xeno/standalone/local_secret"
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      secret = Xeno::Standalone.local_secret(root)
      path = root.join("storage", ".local_secret")

      assert_equal secret, path.read.strip
      assert_equal "600", format("%o", path.stat.mode & 0o777)

      File.chmod(0o644, path) # a pre-existing loose file
      Xeno::Standalone.local_secret(root)
      assert_equal "600", format("%o", path.stat.mode & 0o777), "loose files are tightened on read"
    end
  end

  test "standalone puma config binds loopback by default with a HOST opt-out (S4)" do
    config = File.read(File.expand_path("../lib/xeno/standalone/puma.rb", __dir__))
    assert_match(/HOST.*127\.0\.0\.1/, config, "default bind must be loopback with HOST opt-out")
    refute_match(/^port /, config, "a bare port directive would listen on 0.0.0.0")
  end
end

# The dev UI must not reference assets the engine cannot serve — standalone
# and propshaft-less mounts got a RoutingError for
# /stylesheets/xeno/application.css on every page load (field finding).
class DevUiStylesheetTest < ActionDispatch::IntegrationTest
  setup { ENV["XENO_DEV_ROUTES"] = "1" }
  teardown { ENV.delete("XENO_DEV_ROUTES") }

  test "dev UI pages carry inline styles, no stylesheet link" do
    get "/agent/dev"
    assert_response :success
    refute_match(/stylesheet/, response.body, "styles must be inline, not linked")
    assert_match(/<style>/, response.body)
  end
end
