require "test_helper"

# H3 regression: Event.append! and Turn.append! retry create! after a unique
# violation, and both are routinely called INSIDE enclosing transactions
# (emit in open!/stage_turn!/finish!, Turn.append! in stage_turn!). On
# Postgres a failed INSERT aborts the whole transaction — the retry raises
# PG::InFailedSqlTransaction — unless the INSERT runs in its own savepoint
# (transaction(requires_new: true)). SQLite forgives this, so the sqlite
# suite asserts the mechanism: a savepoint is issued around the insert
# whenever a transaction is already open.
class AppendSavepointTest < ActiveSupport::TestCase
  def build_session
    start_fake_llm
    Xeno::Session.open!(message: "hi", definition: TestDefinition.new)
  end

  def savepoints_during
    statements = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      statements << event.payload[:sql]
    end
    yield
    statements.grep(/\ASAVEPOINT/i)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  test "Event.append! inserts inside a savepoint when a transaction is open" do
    session = build_session

    # Materialize the outer transaction BEFORE subscribing (transactions are
    # lazy since Rails 7.2 — the outer BEGIN/SAVEPOINT would otherwise fire
    # inside the measurement window and mask a missing requires_new).
    ActiveRecord::Base.transaction do
      Xeno::Event.count
      savepoints = savepoints_during { Xeno::Event.append!(session, "test.event") }
      assert savepoints.any?,
             "the event INSERT must run in its own savepoint (PG aborts the enclosing transaction otherwise)"
    end
  end

  test "Turn.append! inserts inside a savepoint when a transaction is open" do
    session = build_session

    ActiveRecord::Base.transaction do
      Xeno::Turn.count
      savepoints = savepoints_during { Xeno::Turn.append!(session, user_message: { contents: [ "x" ] }) }
      assert savepoints.any?,
             "the turn INSERT must run in its own savepoint (PG aborts the enclosing transaction otherwise)"
    end
  end

  test "a colliding insert recovers inside an enclosing transaction" do
    session = build_session
    session.emit("occupied") # takes the next index

    # Force one collision: the first computed index is stale because a
    # competing writer (simulated here) grabs it between the SELECT and the
    # INSERT. The savepoint lets the retry proceed inside the transaction.
    competing_done = false
    original = Xeno::Event.method(:create!)
    Xeno::Event.define_singleton_method(:create!) do |attrs|
      unless competing_done
        competing_done = true
        original.call(attrs.merge(event_type: "competitor"))
      end
      original.call(attrs)
    end

    begin
      event = nil
      ActiveRecord::Base.transaction do
        event = Xeno::Event.append!(session, "after.collision")
      end
      assert_equal "after.collision", event.event_type
      assert_equal session.events.maximum(:index), event.index
    ensure
      Xeno::Event.singleton_class.remove_method(:create!)
    end
  end
end
