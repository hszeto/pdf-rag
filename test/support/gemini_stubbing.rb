# Swaps GeminiClient's transport for the duration of a test and restores it
# afterwards. Tests run in parallel as separate processes, so mutating the
# per-process setting cannot leak between workers.
module GeminiStubbing
  def stub_gemini(*responses)
    fake = FakeGeminiTransport.new(*responses)
    previous = GeminiClient.transport_factory
    GeminiClient.transport_factory = -> { fake }
    yield fake
  ensure
    GeminiClient.transport_factory = previous
  end

  # A well-formed analysis payload, overridable per test.
  def gemini_analysis(**overrides)
    {
      "is_insurance_document" => true,
      "document_type" => "Summary of Benefits",
      "structured_fields" => {
        "member_name" => "Jane Q. Sample",
        "plan_type" => "Medicare Advantage (HMO)",
        "plan_name" => "ACME Health Gold Advantage",
        "insurance_id" => "ACM-000-123-456",
        "copay_primary_care" => "$20",
        "copay_specialist" => "$45",
        "deductible" => "$1,500",
        "plan_year" => "2026",
        "customer_service_phone" => "1-800-555-0142"
      },
      "plain_summary" => "Your plan is called ACME Health Gold Advantage."
    }.merge(overrides.transform_keys(&:to_s))
  end
end
