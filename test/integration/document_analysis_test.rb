require "test_helper"

class DocumentAnalysisTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  # The request no longer waits for the model. It extracts, hands off, and
  # returns; the reader gets a screen that says so (R7.2, D6).
  test "the upload returns straight away and leaves the session analysing" do
    stub_gemini(gemini_analysis) do |fake|
      upload_pdf

      assert_redirected_to root_path
      assert_equal "analyzing", insurance_session.status
      assert_equal 0, fake.call_count, "the request itself must not call the model"
    end
  end

  test "the analysis is enqueued with only the session id" do
    stub_gemini(gemini_analysis) do
      assert_enqueued_with(job: AnalyzeDocumentJob, args: ->(args) { args == [ session_id ] }) do
        upload_pdf
      end
    end
  end

  test "the reader is shown the processing screen while it runs" do
    stub_gemini(gemini_analysis) { upload_pdf }

    get root_path

    assert_response :success
    assert_select "h1", /Reading your document/i
    assert_select "[data-controller=processing]"
  end

  # AC 11
  test "a valid insurance PDF costs exactly one Gemini call and reaches extracted" do
    upload_and_analyze do |fake|
      assert_equal 1, fake.call_count, "the upload must cost exactly one call"
    end

    assert_equal "extracted", insurance_session.status
  end

  test "the extracted fields and summary are stored on the session" do
    upload_and_analyze

    session = insurance_session
    assert_equal "Jane Q. Sample", session.field(:member_name)
    assert_equal "$20", session.field(:copay_primary_care)
    assert_equal "1-800-555-0142", session.field(:customer_service_phone)
    assert_includes session.plain_summary, "ACME Health Gold Advantage"
  end

  test "the document text is what gets sent for analysis" do
    upload_and_analyze do |fake|
      assert_includes fake.prompt_for, "ACME HEALTH GOLD ADVANTAGE PLAN"
      assert_includes fake.prompt_for, "1-800-555-0142"
    end
  end

  # AC 13
  test "a non-insurance PDF is refused, discarded, and costs no further calls" do
    payload = gemini_analysis(is_insurance_document: false, structured_fields: {},
      plain_summary: "This is a restaurant menu.")

    upload_and_analyze("restaurant_menu.pdf", payload) do |fake|
      assert_equal 1, fake.call_count, "one call to classify, and no more"
    end

    get root_path

    assert_select "[role=alert]", /does not look like an insurance document/i
    assert_select "input[type=file]", 1, "the refusal must come with a way to try again"
  end

  test "a refused document is not left sitting in the cache" do
    payload = gemini_analysis(is_insurance_document: false, structured_fields: {})

    upload_and_analyze("restaurant_menu.pdf", payload)

    session = insurance_session
    assert_nil session.full_text, "the text of a refused document must be discarded"
    assert_nil session.plain_summary
    assert_equal "error", session.status
  end

  # The failure now happens inside the job, so it has to reach the reader through
  # the session rather than through the response that triggered it.
  test "an overloaded model leaves a friendly message on the next screen" do
    empty = { candidates: [ { content: { parts: [] } } ] }.to_json

    upload_and_analyze("insurance_sample.pdf", [ 200, empty ])

    get root_path

    assert_select "[role=alert]", /trouble reading documents/i
    assert_select "input[type=file]", 1
  end

  test "an upstream error leaves nothing half-written on the session" do
    upload_and_analyze("insurance_sample.pdf", [ 503, "unavailable" ])

    session = insurance_session
    assert_equal "error", session.status
    assert_nil session.full_text
    assert_match(/trouble reading documents/i, session.error_message)
  end

  test "a document refused before analysis never reaches Gemini" do
    stub_gemini do |fake|
      perform_enqueued_jobs { upload_pdf("actually_a_jpeg.pdf") }

      assert_equal 0, fake.call_count, "a file that is not a PDF must not be sent anywhere"
    end
  end

  test "a scanned document never reaches Gemini" do
    stub_gemini do |fake|
      perform_enqueued_jobs { upload_pdf("text_light.pdf") }

      assert_equal 0, fake.call_count, "vision is deferred, so no call should be made"
    end
  end

  # A slow queue and a five minute TTL will eventually meet.
  test "a job whose session expired first does nothing" do
    stub_gemini(gemini_analysis) { upload_pdf }
    id = session_id

    travel(SessionCache::TTL + 1.second) do
      stub_gemini(gemini_analysis) do |fake|
        perform_enqueued_jobs

        assert_equal 0, fake.call_count, "an expired session must not be analysed"
      end
    end

    assert_nil SessionCache.find(id)
  end

  test "a job for a session that was explicitly removed does nothing" do
    stub_gemini(gemini_analysis) { upload_pdf }
    delete session_path

    stub_gemini(gemini_analysis) do |fake|
      perform_enqueued_jobs

      assert_equal 0, fake.call_count
    end
  end
end
