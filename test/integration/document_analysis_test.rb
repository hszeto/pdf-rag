require "test_helper"

class DocumentAnalysisTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  # AC 11
  test "a valid insurance PDF costs exactly one Gemini call and reaches extracted" do
    stub_gemini(gemini_analysis) do |fake|
      post document_path, params: { document: upload("insurance_sample.pdf") }

      assert_equal 1, fake.call_count, "the upload must cost exactly one call"
    end

    assert_equal "extracted", SessionCache.find(session_id).status
  end

  test "the extracted fields and summary are stored on the session" do
    stub_gemini(gemini_analysis) do
      post document_path, params: { document: upload("insurance_sample.pdf") }
    end

    session = SessionCache.find(session_id)
    assert_equal "Jane Q. Sample", session.field(:member_name)
    assert_equal "$20", session.field(:copay_primary_care)
    assert_equal "1-800-555-0142", session.field(:customer_service_phone)
    assert_includes session.plain_summary, "ACME Health Gold Advantage"
  end

  test "the document text is what gets sent for analysis" do
    stub_gemini(gemini_analysis) do |fake|
      post document_path, params: { document: upload("insurance_sample.pdf") }

      assert_includes fake.prompt_for, "ACME HEALTH GOLD ADVANTAGE PLAN"
      assert_includes fake.prompt_for, "1-800-555-0142"
    end
  end

  # AC 13
  test "a non-insurance PDF is refused, discarded, and costs no further calls" do
    payload = gemini_analysis(is_insurance_document: false, structured_fields: {},
      plain_summary: "This is a restaurant menu.")

    stub_gemini(payload) do |fake|
      post document_path, params: { document: upload("restaurant_menu.pdf") }

      assert_equal 1, fake.call_count, "one call to classify, and no more"
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /does not look like an insurance document/i
    assert_select "input[type=file]", 1, "the refusal must come with a way to try again"
  end

  test "a refused document is not left sitting in the cache" do
    payload = gemini_analysis(is_insurance_document: false, structured_fields: {})

    stub_gemini(payload) do
      post document_path, params: { document: upload("restaurant_menu.pdf") }
    end

    session = SessionCache.find(session_id)
    assert_nil session.full_text, "the text of a refused document must be discarded"
    assert_nil session.plain_summary
    assert_equal "error", session.status
  end

  test "an overloaded model shows a friendly message rather than crashing" do
    empty = { candidates: [ { content: { parts: [] } } ] }.to_json

    stub_gemini([ 200, empty ]) do
      post document_path, params: { document: upload("insurance_sample.pdf") }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /trouble reading documents/i
    assert_select "input[type=file]", 1
  end

  test "an upstream error leaves nothing half-written on the session" do
    stub_gemini([ 503, "unavailable" ]) do
      post document_path, params: { document: upload("insurance_sample.pdf") }
    end

    session = SessionCache.find(session_id)
    assert_equal "empty", session.status
    assert_nil session.full_text
  end

  test "a document refused before analysis never reaches Gemini" do
    stub_gemini do |fake|
      post document_path, params: { document: upload("actually_a_jpeg.pdf") }

      assert_equal 0, fake.call_count, "a file that is not a PDF must not be sent anywhere"
    end
  end

  test "a scanned document never reaches Gemini" do
    stub_gemini do |fake|
      post document_path, params: { document: upload("text_light.pdf") }

      assert_equal 0, fake.call_count, "vision is deferred, so no call should be made"
    end
  end

  private
    def upload(name) = fixture_file_upload(name, "application/pdf")

    def session_id = session[SessionScoped::SESSION_KEY]
end
