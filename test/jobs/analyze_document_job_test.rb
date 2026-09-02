require "test_helper"

class AnalyzeDocumentJobTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @session = SessionCache.create
    @session.full_text = "ACME plan. Deductible $1,500."
    @session.status = "analyzing"
    SessionCache.write(@session)
  end

  test "stores what the model found and settles the status" do
    run_job

    session = reload
    assert_equal "extracted", session.status
    assert_equal "$1,500", session.field(:deductible)
    assert_equal "Summary of Benefits", session.document_type
    assert_nil session.error_message
  end

  # Only the id crosses the queue: the text is already in the cache, so no
  # document content is written into Redis as a job argument (R3.5).
  test "takes only a session id as its argument" do
    stub_gemini(gemini_analysis) do
      assert_enqueued_with(job: AnalyzeDocumentJob, args: [ @session.session_id ]) do
        AnalyzeDocumentJob.perform_later(@session.session_id)
      end
    end
  end

  test "discards a document that is not insurance" do
    run_job(gemini_analysis(is_insurance_document: false, structured_fields: {}))

    session = reload
    assert_equal "error", session.status
    assert_nil session.full_text, "a document we cannot use must not sit in the cache"
    assert_match(/does not look like an insurance document/i, session.error_message)
  end

  # The reader is watching a spinner. A failure has to stop it, which means
  # recording the outcome rather than letting the job raise into Sidekiq retries
  # that will outlive the session.
  test "records an upstream failure instead of raising" do
    assert_nothing_raised { run_job([ 503, "unavailable" ]) }

    session = reload
    assert_equal "error", session.status
    assert_match(/trouble reading documents/i, session.error_message)
  end

  test "records a malformed response instead of raising" do
    envelope = { candidates: [ { content: { parts: [ { text: "not json" } ] } } ] }.to_json

    assert_nothing_raised { run_job([ 200, envelope ]) }

    assert_equal "error", reload.status
  end

  test "does nothing when the session expired while queued" do
    SessionCache.destroy(@session.session_id)

    stub_gemini(gemini_analysis) do |fake|
      assert_nothing_raised { AnalyzeDocumentJob.perform_now(@session.session_id) }

      assert_equal 0, fake.call_count
    end
  end

  # Guards against a duplicate delivery re-analysing a document, and against a
  # job landing after the reader already replaced the document.
  test "does nothing when the session is no longer analysing" do
    @session.status = "extracted"
    SessionCache.write(@session)

    stub_gemini(gemini_analysis) do |fake|
      AnalyzeDocumentJob.perform_now(@session.session_id)

      assert_equal 0, fake.call_count
    end
  end

  test "analysing refreshes the idle timer so the reader does not expire mid-wait" do
    travel(4.minutes) { run_job }

    travel(8.minutes) { assert_not_nil SessionCache.find(@session.session_id) }
  end

  private
    def run_job(response = nil)
      stub_gemini(response || gemini_analysis) do
        AnalyzeDocumentJob.perform_now(@session.session_id)
      end
    end

    def reload = SessionCache.find(@session.session_id)
end
