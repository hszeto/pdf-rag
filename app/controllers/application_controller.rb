class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  include SessionScoped

  # Every failure the pipeline can raise already carries the words the user
  # should see, so one handler covers all of them and no path can dead-end on an
  # unhandled exception (R7.5).
  rescue_from ProcessingError, with: :render_processing_error

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    # Rendered rather than redirected so the message arrives alongside the retry
    # control on the same screen, and so a failure on the landing page itself
    # cannot bounce into a redirect loop.
    def render_processing_error(error)
      flash.now[:alert] = error.user_message
      render "sessions/show", status: :unprocessable_entity
    end
end
