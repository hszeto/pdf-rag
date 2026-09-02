require "test_helper"

class SessionLifecycleTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  # AC 1
  test "visiting the root issues a session and stores it in the cache" do
    get root_path

    assert_response :success
    assert_not_nil session_id, "expected an id in the signed session cookie"
    assert_not_nil SessionCache.find(session_id)
  end

  # AC 1: the id must not be readable or forgeable client-side. Rails' session
  # cookie is signed and httpOnly, which is why we ride it (D10).
  test "the session cookie is httpOnly and does not expose the raw id" do
    get root_path

    set_cookie = response.headers["Set-Cookie"].to_s
    assert_match(/HttpOnly/i, set_cookie)
    assert_no_match(/#{Regexp.escape(session_id)}/, set_cookie,
      "the raw session id must not appear in the cookie value")
  end

  test "the same visitor keeps one session across requests" do
    get root_path
    first = session_id

    get root_path

    assert_equal first, session_id
    assert_equal 1, cache_session_count
  end

  # AC 2
  test "a heartbeat refreshes the TTL" do
    get root_path
    id = session_id

    travel(4.minutes) do
      post heartbeat_path
      assert_response :no_content
    end

    travel(8.minutes) do
      assert_not_nil SessionCache.find(id),
        "the heartbeat at 4 minutes should have kept the session alive to 8"
    end
  end

  # AC 3
  test "an expired session renders the landing screen with the removal notice" do
    get root_path

    travel(SessionCache::TTL + 1.second) do
      get root_path

      assert_response :success
      assert_select "[role=status]", /removed to keep your information private/i
    end
  end

  test "a heartbeat after expiry reports gone rather than erroring" do
    get root_path

    travel(SessionCache::TTL + 1.second) do
      post heartbeat_path
      assert_response :gone
    end
  end

  # AC 4
  test "deleting the session wipes it immediately" do
    get root_path
    id = session_id

    delete session_path

    assert_redirected_to root_path
    assert_nil SessionCache.find(id)
  end

  # AC 5: an id that no longer resolves must behave exactly like an expired one —
  # no error, no leak, no other visitor's data. Dropping the cache entry while the
  # cookie still carries the id reproduces precisely that state.
  test "a session id that no longer resolves is treated the same as an expired one" do
    other = SessionCache.create
    other.status = "extracted"
    other.plain_summary = "A document belonging to somebody else."
    SessionCache.write(other)

    get root_path
    SessionCache.destroy(session_id)

    get root_path

    assert_response :success
    assert_select "[role=status]", /removed to keep your information private/i
    assert_no_match(/belonging to somebody else/, response.body)
    assert_not_nil SessionCache.find(other.session_id), "the other session must be untouched"
  end

  test "a fresh visitor sees no removal notice" do
    get root_path

    assert_response :success
    assert_select "[role=status]", false, "a first-time visitor has nothing to be told about"
  end

  private
    def session_id = session[SessionScoped::SESSION_KEY]

    def cache_session_count
      # MemoryStore exposes its keys; enough to assert we are not leaking sessions.
      Rails.cache.instance_variable_get(:@data).keys.count { |k| k.include?(SessionCache::KEY_PREFIX) }
    end
end
