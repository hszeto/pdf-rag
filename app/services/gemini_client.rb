require "net/http"

# Talks to Gemini. One call per upload (R5.1); the Q&A calls arrive with the
# chat loop in a later checkpoint.
#
# The transport is injected so the payload can be asserted and every failure mode
# driven without a network. That is not stylistic: this project has no mocking
# library at all, so a seam is the only way to test any of it. It also keeps the
# call inside a plain service object, which is what lets a background job wrap it
# later without restructuring (D6).
class GeminiClient
  MODEL = "gemini-2.5-flash".freeze
  BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models".freeze

  # Thinking is off by default. It is on in the API unless disabled, and a
  # trivial call measured 21 tokens with it versus 6 without (D7). Thinking
  # tokens also count against max_output_tokens, so leaving it on with a tight
  # ceiling returns an empty response that reads like a bug.
  THINKING_BUDGET = 0
  MAX_OUTPUT_TOKENS = 2048
  TEMPERATURE = 0.1

  NULLABLE_STRING = { type: "STRING", nullable: true }.freeze

  ANALYSIS_SCHEMA = {
    type: "OBJECT",
    properties: {
      is_insurance_document: { type: "BOOLEAN" },
      document_type: NULLABLE_STRING,
      structured_fields: {
        type: "OBJECT",
        properties: InsuranceSession::FIELD_KEYS.index_with { NULLABLE_STRING }
      },
      plain_summary: { type: "STRING" }
    },
    required: %w[is_insurance_document plain_summary]
  }.freeze

  ANALYSIS_PROMPT = <<~PROMPT.freeze
    You are reading a document that someone believes is about their health insurance.

    First decide whether it really is an insurance document — a plan summary, a
    summary of benefits, an insurance card, an explanation of benefits, or similar.
    A menu, a receipt, a letter or an article is not.

    If it is, pull out the listed fields and write a short plain-language summary.

    Rules for the fields:
    - Copy values exactly as they appear in the document.
    - If a field does not appear in the document, return null for it.
    - Never guess, infer, estimate or calculate a value. A wrong number here could
      cost this person money or medical care. Returning null is always better than
      a plausible guess.

    Rules for the summary:
    - Write for an older adult who is not familiar with insurance jargon.
    - Short sentences. Everyday words. Warm and calm.
    - Cover what they pay: deductible, common copays, and the out-of-pocket maximum.
    - Do not add anything that is not in the document.

    The document text follows.
  PROMPT

  Analysis = Struct.new(:insurance, :document_type, :structured_fields, :plain_summary, keyword_init: true) do
    def insurance? = insurance
  end

  # Swapped wholesale in tests. This project has no mocking library, so the
  # seam is an explicit setting rather than a stubbing DSL. The test suite
  # replaces it with one that refuses to make a call, so a test that forgets a
  # stub fails loudly instead of quietly reaching the live API.
  mattr_accessor :transport_factory, default: -> { NetHttpTransport.new }

  def initialize(transport: nil, api_key: nil)
    @transport = transport || transport_factory.call
    @api_key = api_key || Rails.application.credentials.gemini_api_key
  end

  def analyze_document(text)
    payload = {
      contents: [ { parts: [ { text: "#{ANALYSIS_PROMPT}\n\n#{text}" } ] } ],
      generationConfig: generation_config.merge(
        responseMimeType: "application/json",
        responseSchema: ANALYSIS_SCHEMA
      )
    }

    parsed = request(payload)

    Analysis.new(
      insurance: parsed["is_insurance_document"] == true,
      document_type: parsed["document_type"],
      structured_fields: normalize_fields(parsed["structured_fields"]),
      plain_summary: parsed["plain_summary"].to_s
    )
  end

  private
    def generation_config
      {
        temperature: TEMPERATURE,
        maxOutputTokens: MAX_OUTPUT_TOKENS,
        thinkingConfig: { thinkingBudget: THINKING_BUDGET }
      }
    end

    def request(payload)
      raise ProcessingError::ServiceUnavailable, "no api key configured" if @api_key.blank?

      response = @transport.call(
        url: "#{BASE_URL}/#{MODEL}:generateContent",
        # The key travels as a header rather than a query parameter so it never
        # reaches a URL, a referrer, or an access log.
        headers: { "content-type" => "application/json", "x-goog-api-key" => @api_key },
        body: payload.to_json
      )

      raise ProcessingError::ServiceUnavailable, "http #{response.status}" unless response.ok?

      parse(response.body)
    end

    def parse(body)
      envelope = JSON.parse(body.to_s)
      text = envelope.dig("candidates", 0, "content", "parts", 0, "text")

      # An overloaded model answers 200 with no candidate, no finishReason and no
      # error status. Observed live. Without this it becomes a confusing nil
      # chase rather than a message the user can act on.
      raise ProcessingError::ServiceUnavailable, "empty response" if text.blank?

      JSON.parse(text)
    rescue JSON::ParserError => e
      # responseSchema makes this unlikely rather than impossible (R5.6).
      raise ProcessingError::ServiceUnavailable, "unparseable response: #{e.message}"
    end

    # Always return every field, so a key the model omitted still renders as
    # "not found" rather than vanishing from the plan screen (R7.3).
    def normalize_fields(fields)
      given = (fields || {}).symbolize_keys
      InsuranceSession::FIELD_KEYS.index_with do |key|
        value = given[key]
        value.presence if value.is_a?(String)
      end
    end
end
