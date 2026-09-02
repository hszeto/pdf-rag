# All session state lives here, in the cache, with a hard TTL — nothing touches
# disk or a database. Every write resets the TTL, so R1.3's "refresh on every
# interaction" falls out of ordinary use instead of needing its own code path.
class SessionCache
  TTL = 300.seconds
  KEY_PREFIX = "insurance_session".freeze

  class << self
    def create
      session = InsuranceSession.new(
        session_id: SecureRandom.uuid,
        status: "empty",
        created_at: Time.current,
        last_active_at: Time.current
      )
      write(session)
      session
    end

    def find(id)
      return nil if id.blank?

      InsuranceSession.from_h(store.read(key_for(id)))
    end

    # Raises rather than failing quietly when the store rejects the write. The
    # configured error_handler swallows Redis failures and returns nil, so without
    # this an upload would report success and then vanish on the next request,
    # which reads to the user like their document was lost (R3.6).
    def write(session)
      session.last_active_at = Time.current
      ok = store.write(key_for(session.session_id), session.to_h, expires_in: TTL)
      raise ProcessingError::StorageFailure unless ok

      session
    end

    # Refresh the TTL without otherwise changing the session. Returns false when
    # the session has already expired, so callers can tell the two cases apart.
    def touch(id)
      session = find(id)
      return false if session.nil?

      write(session)
      true
    end

    def destroy(id)
      store.delete(key_for(id)) if id.present?
    end

    def key_for(id) = "#{KEY_PREFIX}:#{id}"

    private
      def store = Rails.cache
  end
end
