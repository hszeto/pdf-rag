require "test_helper"

# D9. Rails' limiter treats a nil from increment as "no limit", so a cache that
# is down switches rate limiting off and only a log line says so. This app's
# cache makes that likelier: its error_handler logs and swallows, and the free
# Key Value instance evicts under memory pressure.
class FailClosedStoreTest < ActiveSupport::TestCase
  # The assumption the whole design rests on: nil means the store failed, and
  # never "this is the first request".
  test "a real store counts from one rather than returning nil" do
    store = FailClosedStore.new(ActiveSupport::Cache::MemoryStore.new)

    assert_equal 1, store.increment("fresh-key", 1, expires_in: 60)
    assert_equal 2, store.increment("fresh-key", 1, expires_in: 60)
  end

  test "a store that cannot count refuses instead of admitting" do
    store = FailClosedStore.new(broken_store)

    assert_raises(ProcessingError::LimiterUnavailable) do
      store.increment("any-key", 1, expires_in: 60)
    end
  end

  # R4.4: distinguishable from a genuine limit hit, by type rather than by
  # parsing a message.
  test "the refusal is not the same error as reaching a limit" do
    error = ProcessingError::LimiterUnavailable.new

    assert_not_kind_of ProcessingError::TooManyDocuments, error
    assert_not_kind_of ProcessingError::TooManyQuestions, error
  end

  test "the reader is told, and it is not blamed on them" do
    error = ProcessingError::LimiterUnavailable.new

    assert_match(/try again in a moment/i, error.user_message)
    assert_equal :service_unavailable, error.status
  end

  test "reaching a limit answers 429" do
    assert_equal :too_many_requests, ProcessingError::TooManyDocuments.new.status
    assert_equal :too_many_requests, ProcessingError::TooManyQuestions.new.status
  end

  private
    # Stands in for the cache swallowing an error and returning nil, which is
    # exactly what production.rb's error_handler does.
    def broken_store
      Class.new do
        def increment(*, **) = nil
      end.new
    end
end
