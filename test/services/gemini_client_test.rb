require "test_helper"

class GeminiClientTest < ActiveSupport::TestCase
  test "asks the configured model at the documented endpoint" do
    fake = FakeGeminiTransport.new(gemini_analysis)

    client(fake).analyze_document("some text")

    assert_equal 1, fake.call_count
    assert_equal "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
      fake.calls.first[:url]
  end

  # The key must never reach a URL, a referrer or an access log (D7).
  test "sends the api key as a header, never in the url" do
    fake = FakeGeminiTransport.new(gemini_analysis)

    client(fake, api_key: "secret-key-value").analyze_document("some text")

    assert_equal "secret-key-value", fake.calls.first[:headers]["x-goog-api-key"]
    assert_no_match(/secret-key-value/, fake.calls.first[:url])
  end

  # Thinking is on by default in the API and costs real tokens for no benefit on
  # this call; measured 21 tokens with it versus 6 without (D7).
  test "disables thinking and keeps the temperature low" do
    fake = FakeGeminiTransport.new(gemini_analysis)

    client(fake).analyze_document("some text")

    config = fake.generation_config
    assert_equal 0, config.dig("thinkingConfig", "thinkingBudget")
    assert_operator config["temperature"], :<=, 0.2
  end

  # Structured output is what keeps prose and code fences out of the response.
  test "requests JSON against a schema covering every field" do
    fake = FakeGeminiTransport.new(gemini_analysis)

    client(fake).analyze_document("some text")

    config = fake.generation_config
    assert_equal "application/json", config["responseMimeType"]
    schema_fields = config.dig("responseSchema", "properties", "structured_fields", "properties").keys
    assert_equal InsuranceSession::FIELD_KEYS.map(&:to_s).sort, schema_fields.sort
  end

  test "instructs the model never to guess a value" do
    fake = FakeGeminiTransport.new(gemini_analysis)

    client(fake).analyze_document("the document text")

    prompt = fake.prompt_for
    assert_match(/return null/i, prompt)
    assert_match(/never guess/i, prompt)
    assert_includes prompt, "the document text"
  end

  test "parses a successful analysis" do
    analysis = client(FakeGeminiTransport.new(gemini_analysis)).analyze_document("text")

    assert analysis.insurance?
    assert_equal "Summary of Benefits", analysis.document_type
    assert_equal "$1,500", analysis.structured_fields[:deductible]
    assert_equal "1-800-555-0142", analysis.structured_fields[:customer_service_phone]
  end

  test "reports a non-insurance document as such" do
    payload = gemini_analysis(is_insurance_document: false, structured_fields: {})

    analysis = client(FakeGeminiTransport.new(payload)).analyze_document("a menu")

    assert_not analysis.insurance?
  end

  # A field the model omits must still come back as a key, so the plan screen can
  # say "not found" rather than dropping the row (R7.3).
  test "fills in every field even when the model omits some" do
    payload = gemini_analysis(structured_fields: { "deductible" => "$500" })

    analysis = client(FakeGeminiTransport.new(payload)).analyze_document("text")

    assert_equal InsuranceSession::FIELD_KEYS.sort, analysis.structured_fields.keys.sort
    assert_equal "$500", analysis.structured_fields[:deductible]
    assert_nil analysis.structured_fields[:member_name]
  end

  test "treats an empty string field as not found" do
    payload = gemini_analysis(structured_fields: { "deductible" => "" })

    analysis = client(FakeGeminiTransport.new(payload)).analyze_document("text")

    assert_nil analysis.structured_fields[:deductible]
  end

  # Observed live: an overloaded model answers 200 with no candidate, no
  # finishReason and no error status.
  test "an empty candidate becomes a friendly service error" do
    envelope = { candidates: [ { content: { parts: [] } } ] }.to_json

    error = assert_raises(ProcessingError::ServiceUnavailable) do
      client(FakeGeminiTransport.new([ 200, envelope ])).analyze_document("text")
    end

    assert_match(/trouble reading documents/i, error.user_message)
  end

  test "a response that is not JSON becomes a service error, not a crash" do
    envelope = { candidates: [ { content: { parts: [ { text: "I'm sorry, I can't help." } ] } } ] }.to_json

    assert_raises(ProcessingError::ServiceUnavailable) do
      client(FakeGeminiTransport.new([ 200, envelope ])).analyze_document("text")
    end
  end

  test "http failures become service errors" do
    [ 429, 500, 503 ].each do |status|
      assert_raises(ProcessingError::ServiceUnavailable, "HTTP #{status} should be handled") do
        client(FakeGeminiTransport.new([ status, "upstream said no" ])).analyze_document("text")
      end
    end
  end

  test "a network failure becomes a service error" do
    assert_raises(ProcessingError::ServiceUnavailable) do
      client(FakeGeminiTransport.new(ProcessingError::ServiceUnavailable)).analyze_document("text")
    end
  end

  test "a missing api key fails before any call is attempted" do
    fake = FakeGeminiTransport.new(gemini_analysis)

    assert_raises(ProcessingError::ServiceUnavailable) do
      client(fake, api_key: "").analyze_document("text")
    end

    assert_equal 0, fake.call_count, "no request should be attempted without a key"
  end

  private
    def client(transport, api_key: "test-key")
      GeminiClient.new(transport: transport, api_key: api_key)
    end
end
