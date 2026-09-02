require "test_helper"

class SessionCacheTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  test "create issues a non-guessable id and stores an empty session" do
    session = SessionCache.create

    assert_match(/\A[0-9a-f-]{36}\z/, session.session_id)
    assert session.empty?
    assert_equal session.to_h, SessionCache.find(session.session_id).to_h
  end

  test "find returns nil for unknown or blank ids" do
    assert_nil SessionCache.find("does-not-exist")
    assert_nil SessionCache.find(nil)
    assert_nil SessionCache.find("")
  end

  test "the entry survives up to the TTL and is gone after it" do
    id = SessionCache.create.session_id

    travel(SessionCache::TTL - 1.second) { assert_not_nil SessionCache.find(id) }
    travel(SessionCache::TTL + 1.second) { assert_nil SessionCache.find(id) }
  end

  # AC 2: interaction refreshes the TTL. Total elapsed time here exceeds one full
  # TTL, so this fails if touch does not actually reset the clock.
  test "touch refreshes the TTL" do
    id = SessionCache.create.session_id

    travel(4.minutes) do
      assert SessionCache.touch(id), "expected the session to still be alive"
    end

    travel(8.minutes) do
      assert_not_nil SessionCache.find(id),
        "session should survive 8 minutes when touched at the 4 minute mark"
    end
  end

  test "touch reports false once the session has expired" do
    id = SessionCache.create.session_id

    travel(SessionCache::TTL + 1.second) do
      assert_equal false, SessionCache.touch(id)
    end
  end

  test "writing a session refreshes its TTL and persists changes" do
    session = SessionCache.create
    session.status = "extracted"
    session.plain_summary = "A plain summary."
    SessionCache.write(session)

    travel(4.minutes) do
      reloaded = SessionCache.find(session.session_id)
      assert_equal "extracted", reloaded.status
      assert_equal "A plain summary.", reloaded.plain_summary
    end
  end

  test "destroy removes the entry immediately" do
    id = SessionCache.create.session_id

    SessionCache.destroy(id)

    assert_nil SessionCache.find(id)
  end

  test "keys are namespaced per the spec" do
    assert_equal "insurance_session:abc123", SessionCache.key_for("abc123")
  end
end
