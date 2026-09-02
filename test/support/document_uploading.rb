# Uploading is two steps now: the request extracts and enqueues, the job reads.
# These helpers run both, so a test that cares about the outcome does not have to
# spell out the handoff every time.
module DocumentUploading
  def upload_pdf(fixture = "insurance_sample.pdf")
    post document_path, params: {
      document: fixture_file_upload(fixture, "application/pdf")
    }
  end

  # Upload and let the analysis job run, with the given Gemini response in place
  # for the duration. Yields the fake transport for call-count assertions.
  def upload_and_analyze(fixture = "insurance_sample.pdf", response = nil, &block)
    stub_gemini(response || gemini_analysis) do |fake|
      perform_enqueued_jobs { upload_pdf(fixture) }
      block&.call(fake)
    end
  end

  def session_id = session[SessionScoped::SESSION_KEY]

  def insurance_session = SessionCache.find(session_id)
end
