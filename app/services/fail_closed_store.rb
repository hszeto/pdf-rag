# A counter store that refuses rather than shrugs.
#
# Rails' rate limiter reads `store.increment` and treats a nil as "no limit" —
# so a cache that is down silently switches rate limiting off, and only a log
# line says so. This app's cache makes that likelier still: its error_handler
# logs and swallows, and the free Key Value instance evicts under memory
# pressure.
#
# Verified: increment returns 1 for a key that does not exist yet, so nil means
# the store failed and never "this is the first request".
class FailClosedStore
  def initialize(store = nil)
    @store = store
  end

  def increment(name, amount = 1, **options)
    store.increment(name, amount, **options) or raise ProcessingError::LimiterUnavailable
  end

  private
    # Resolved per call rather than at boot, so the controller class can be
    # loaded before the cache is, and so a test can hand in its own.
    def store = @store || Rails.cache
end
