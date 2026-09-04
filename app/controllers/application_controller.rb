class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Every failure the pipeline can raise already carries the words the user
  # should see, so one handler covers all of them and no path can dead-end on an
  # unhandled exception.
  rescue_from ProcessingError, with: :render_processing_error

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    def render_processing_error(error)
      flash.now[:alert] = error.user_message
      render "documents/new", status: error.status
    end
end
