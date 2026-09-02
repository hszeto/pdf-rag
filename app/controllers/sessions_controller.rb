class SessionsController < ApplicationController
  # The single entry point. Which screen renders is driven by the session's
  # status, so expiry needs no special routing — no session simply means landing.
  def show
    ensure_insurance_session
  end

  # Pinged by user activity to keep the document alive (R1.3). Returns :gone once
  # the session has expired so the client can stop asking and reset the UI.
  def heartbeat
    if SessionCache.touch(session[SessionScoped::SESSION_KEY])
      head :no_content
    else
      head :gone
    end
  end

  # Explicit wipe (R1.6). Also reachable automatically via the cache TTL.
  def destroy
    SessionCache.destroy(current_insurance_session&.session_id)
    session.delete(SessionScoped::SESSION_KEY)
    redirect_to root_path
  end
end
