class DocumentsController < ApplicationController
  # One document per session (R3.1). Adding another replaces what came before.
  def create
    ensure_insurance_session

    file = params[:document]
    DocumentValidator.new(file).validate!
    text = PdfExtractionService.new(file).extract!

    analyze_and_store(text)
    redirect_to root_path
  ensure
    # The bytes never outlive the request, whether it succeeded or failed (R3.5).
    discard_tempfile(params[:document])
  end

  private
    # Exactly one Gemini call per upload: classification, field extraction and the
    # plain-language summary all come back together (R5.1).
    def analyze_and_store(text)
      analysis = GeminiClient.new.analyze_document(text)

      return discard_not_insurance unless analysis.insurance?

      session = current_insurance_session
      session.full_text = text
      session.document_type = analysis.document_type
      session.structured_fields = analysis.structured_fields
      session.plain_summary = analysis.plain_summary
      session.status = "extracted"
      SessionCache.write(session)
    end

    # The document is thrown away rather than kept around unread, so a file we
    # have no use for is not sitting in the cache for the next five minutes
    # (R5.2). No further calls are made for it.
    def discard_not_insurance
      session = current_insurance_session
      session.full_text = nil
      session.plain_summary = nil
      session.status = "error"
      SessionCache.write(session)

      raise ProcessingError::NotInsurance
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
