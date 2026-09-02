require "test_helper"

# The generation and embedding calls arrive with the checkpoints that need them.
# What is tested here is the request, response and error handling they share.
class GeminiClientTest < ActiveSupport::TestCase
  test "sends the api key as a header, never in the url" do
    fake = FakeGeminiTransport.new({ "ok" => true })

    client(fake, api_key: "secret-key-value").send(:post, "#{GeminiClient::MODEL}:generateContent", {})

    assert_equal "secret-key-value", fake.calls.first[:headers]["x-goog-api-key"]
    assert_no_match(/secret-key-value/, fake.calls.first[:url])
  end

  test "targets the documented endpoint" do
    fake = FakeGeminiTransport.new({ "ok" => true })

    client(fake).send(:post, "#{GeminiClient::MODEL}:generateContent", {})

    assert_equal "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
      fake.calls.first[:url]
  end

  test "http failures become friendly service errors" do
    [ 429, 500, 503 ].each do |status|
      error = assert_raises(ProcessingError::ServiceUnavailable, "HTTP #{status} should be handled") do
        client(FakeGeminiTransport.new([ status, "upstream said no" ])).send(:post, "x:generateContent", {})
      end
      assert_match(/trouble reading documents/i, error.user_message)
    end
  end

  # Google puts which quota was hit in the body, not the status line.
  test "a quota rejection carries the quota id through to the exception" do
    body = {
      error: {
        message: "You exceeded your current quota",
        details: [ { violations: [ { quotaId: "GenerateRequestsPerDayPerProjectPerModel-FreeTier" } ],
                     retryDelay: "16s" } ]
      }
    }.to_json

    error = assert_raises(ProcessingError::ServiceUnavailable) do
      client(FakeGeminiTransport.new([ 429, body ])).send(:post, "x:generateContent", {})
    end

    assert_match(/GenerateRequestsPerDayPerProjectPerModel-FreeTier/, error.message)
    assert_match(/16s/, error.message)
  end

  test "a response that is not JSON becomes a service error, not a crash" do
    assert_raises(ProcessingError::ServiceUnavailable) do
      client(FakeGeminiTransport.new([ 200, "<html>gateway</html>" ])).send(:post, "x:generateContent", {})
    end
  end

  test "a network failure becomes a service error" do
    assert_raises(ProcessingError::ServiceUnavailable) do
      client(FakeGeminiTransport.new(ProcessingError::ServiceUnavailable)).send(:post, "x:generateContent", {})
    end
  end

  test "a missing api key fails before any call is attempted" do
    fake = FakeGeminiTransport.new({ "ok" => true })

    assert_raises(ProcessingError::ServiceUnavailable) do
      client(fake, api_key: "").send(:post, "x:generateContent", {})
    end

    assert_equal 0, fake.call_count, "no request should be attempted without a key"
  end

  test "thinking is disabled and the temperature is low" do
    config = GeminiClient.new(transport: FakeGeminiTransport.new, api_key: "k").send(:generation_config)

    assert_equal 0, config.dig(:thinkingConfig, :thinkingBudget)
    assert_operator config[:temperature], :<=, 0.2
  end

  private
    def client(transport, api_key: "test-key")
      GeminiClient.new(transport: transport, api_key: api_key)
    end
end
