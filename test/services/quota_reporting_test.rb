require "test_helper"

# AC 18. A per-day cap and a per-minute burst limit are both 429s, and treating
# them the same either wastes retries or tells a reader something untrue.
class QuotaReportingTest < ActiveSupport::TestCase
  test "a daily cap says to come back tomorrow, not in a moment" do
    error = raise_429(quota: "GenerateRequestsPerDayPerProjectPerModel-FreeTier")

    assert_instance_of ProcessingError::QuotaExhausted, error
    assert_match(/tomorrow/i, error.user_message)
    assert_no_match(/in a moment/i, error.user_message)
  end

  test "a burst limit is treated as passing" do
    error = raise_429(quota: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier")

    assert_instance_of ProcessingError::ServiceUnavailable, error
    assert_match(/in a moment/i, error.user_message)
  end

  test "a 429 with no named quota is treated as passing" do
    error = raise_429(quota: nil)

    assert_instance_of ProcessingError::ServiceUnavailable, error
  end

  # A daily cap is still a ServiceUnavailable, so the jobs that retry on it keep
  # working — they simply exhaust their attempts rather than never trying.
  test "a daily cap is still handled by the same rescues" do
    assert_kind_of ProcessingError::ServiceUnavailable, ProcessingError::QuotaExhausted.new("x")
  end

  test "the quota id reaches the exception message for support" do
    error = raise_429(quota: "GenerateRequestsPerDayPerProjectPerModel-FreeTier", retry_delay: "16s")

    assert_match(/GenerateRequestsPerDayPerProjectPerModel-FreeTier/, error.message)
    assert_match(/16s/, error.message)
  end

  private
    def raise_429(quota:, retry_delay: nil)
      violations = quota ? [ { "quotaId" => quota } ] : []
      body = { "error" => {
        "message" => "You exceeded your current quota",
        "details" => [ { "violations" => violations, "retryDelay" => retry_delay }.compact ]
      } }.to_json

      client = GeminiClient.new(transport: FakeGeminiTransport.new([ 429, body ]), api_key: "k")
      begin
        client.send(:post, "x:generateContent", {})
      rescue ProcessingError::ServiceUnavailable => e
        e
      end
    end
end
