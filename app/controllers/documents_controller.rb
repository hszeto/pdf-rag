class DocumentsController < ApplicationController
  # One document per session (R3.1). Adding another replaces what came before.
  def create
    ensure_insurance_session

    file = params[:document]
    DocumentValidator.new(file).validate!
    text = PdfExtractionService.new(file).extract!

    store_document(text)
    redirect_to root_path
  ensure
    # The bytes never outlive the request, whether it succeeded or failed (R3.5).
    discard_tempfile(params[:document])
  end

  private
    def store_document(text)
      session = current_insurance_session
      session.full_text = text
      session.status = "uploaded"
      SessionCache.write(session)
    end

    # Rack cleans multipart tempfiles up at the end of the request anyway, but
    # this app promises the document is gone the moment it is done with it, so
    # it is unlinked explicitly rather than left to the request lifecycle.
    def discard_tempfile(file)
      file.tempfile.close! if file.respond_to?(:tempfile) && file.tempfile
    rescue IOError, Errno::ENOENT
      nil
    end
end
