class DocumentsController < ApplicationController
  # One document per session (R3.1). Adding another replaces what came before.
  #
  # Validation and text extraction stay on the request: both are bounded — the
  # size check is a stat, and extraction is capped at twenty pages (D12). The
  # analysis call is the unbounded part, so it goes to a job (D6).
  def create
    ensure_insurance_session

    file = params[:document]
    DocumentValidator.new(file).validate!
    text = PdfExtractionService.new(file).extract!

    hand_off_for_analysis(text)
    redirect_to root_path
  ensure
    # The bytes never outlive the request, whether it succeeded or failed (R3.5).
    discard_tempfile(params[:document])
  end

  private
    def hand_off_for_analysis(text)
      session = current_insurance_session
      session.full_text = text
      session.document_type = nil
      session.structured_fields = InsuranceSession::FIELD_KEYS.index_with(nil)
      session.plain_summary = nil
      session.error_message = nil
      session.chat_history = []
      session.status = "analyzing"
      session.analyzing_since = Time.current
      SessionCache.write(session)

      AnalyzeDocumentJob.perform_later(session.session_id)
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
