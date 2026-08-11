# frozen_string_literal: true

require "test_helper"

class EventsTest < ActiveSupport::TestCase
  def build_session
    start_fake_llm
    definition = TestDefinition.new
    Xeno::Session.open!(message: "hi", definition: definition)
  end

  test "indexes are per-session, dense, and start at zero" do
    session = build_session
    5.times { |i| session.emit("test.event", { i: i }) }

    indexes = session.events.order(:index).pluck(:index)
    assert_equal (0...indexes.size).to_a, indexes, "indexes must be dense from 0"

    other = build_session
    assert_equal 0, (other.events.order(:index).pluck(:index)).first, "each session has its own cursor"
  end

  test "envelope carries type, data, and meta cursor" do
    session = build_session
    event = session.emit("message.completed", { content: "hi" })

    envelope = event.envelope
    assert_equal "message.completed", envelope["type"]
    assert_equal({ content: "hi" }.stringify_keys, envelope["data"])
    assert_equal event.index, envelope.dig("meta", "index")
    assert Time.iso8601(envelope.dig("meta", "at"))
  end
end

# Non-transactional so each thread gets a REAL connection: under
# transactional fixtures every thread shares the test transaction's
# connection (serializing the "race"), and on Postgres that sharing breaks
# outright. Committed rows also make this the true H3 scenario — separate
# connections colliding on the unique index and recovering via the
# savepoint retry.
class ConcurrentEventsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    chat = @session&.chat
    @session&.destroy
    chat&.destroy
  end

  test "concurrent emitters never collide or leave gaps" do
    start_fake_llm
    @session = Xeno::Session.open!(message: "hi", definition: TestDefinition.new)
    session = @session
    before = session.events.count

    threads = 4.times.map do |t|
      Thread.new do
        5.times { |i| Xeno::Event.append!(session, "thread.event", { t: t, i: i }) }
      end
    end
    threads.each(&:join)

    indexes = session.events.order(:index).pluck(:index)
    assert_equal before + 20, indexes.size
    assert_equal indexes.sort, indexes
    assert_equal indexes.uniq, indexes, "no duplicate indexes"
    assert_equal (indexes.first..indexes.last).to_a, indexes, "no gaps"
  end
end
