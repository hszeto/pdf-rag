# Loads the session behind every request and keeps its TTL fresh.
#
# The id rides Rails' own signed, httpOnly session cookie (D10), so there is no
# hand-rolled cookie and no session-creation endpoint. An id that no longer
# resolves — expired, or never issued by us — is treated identically: the user
# gets the "your document was removed" landing state, never an error and never
# another session's data (R1.5).
module SessionScoped
  extend ActiveSupport::Concern

  SESSION_KEY = :insurance_session_id

  included do
    before_action :load_insurance_session
    helper_method :current_insurance_session, :session_expired?
  end

  private
    def load_insurance_session
      id = session[SESSION_KEY]
      @current_insurance_session = SessionCache.find(id)

      # Distinguish "had an id that no longer resolves" from "never had one",
      # so only the former sees the removal notice.
      @session_expired = id.present? && @current_insurance_session.nil?
      session.delete(SESSION_KEY) if @session_expired
    end

    def current_insurance_session = @current_insurance_session

    def session_expired? = @session_expired.present?

    def ensure_insurance_session
      @current_insurance_session ||= SessionCache.create.tap do |s|
        session[SESSION_KEY] = s.session_id
      end
    end

    # Called by any interaction that should count as activity (R1.3).
    def touch_insurance_session
      SessionCache.write(@current_insurance_session) if @current_insurance_session
    end
end
