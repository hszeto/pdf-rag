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


  ANSWER_SCHEMA = {
    type: "OBJECT",
    properties: {
      answer: { type: "STRING" },
      found_in_summary: { type: "BOOLEAN" }
    },
    required: %w[answer found_in_summary]
  }.freeze

  ANSWER_PROMPT = <<~PROMPT.freeze
    You are helping an older adult understand their own health insurance.

    How to write:
    - Short sentences. Everyday words. No insurance jargon.
    - Warm and calm, the way a helpful person at a desk would speak.
    - Two or three sentences is usually enough.

    What you may say:
    - Answer only from the information given below. It is the only thing you know.
    - Never use general knowledge about insurance. Plans differ, and a confident
      wrong answer could cost this person money or medical care.
    - If the information below does not answer the question, set found_in_summary
      to false, say plainly that this document does not cover it, and tell them
      to call their plan.

    Set found_in_summary to true only when the information below actually
    contains the answer.
  PROMPT

  Answer = Struct.new(:text, :found, keyword_init: true) do
    def found? = found
  end

  # One Q&A turn. The caller decides what `context` is: normally the plain
  # summary, and on the single retry the full document text (R6.1, R6.4).
  def answer(question:, context:, history: [], phone: nil)
    payload = {
      contents: [ { parts: [ { text: answer_prompt(question, context, history, phone) } ] } ],
      generationConfig: generation_config.merge(
        responseMimeType: "application/json",
        responseSchema: ANSWER_SCHEMA
      )
    }

    parsed = request(payload)

    Answer.new(
      text: parsed["answer"].to_s,
      found: parsed["found_in_summary"] == true
    )
  end
  private

    def answer_prompt(question, context, history, phone)
      sections = [ ANSWER_PROMPT ]
      sections << "The number they can call is #{phone}." if phone.present?
      sections << "Information from their document:\n#{context}"

      if history.any?
        conversation = history.map do |turn|
          speaker = turn[:role].to_s == "user" ? "They asked" : "You answered"
          "#{speaker}: #{turn[:content]}"
        end
        sections << "Earlier in this conversation:\n#{conversation.join("\n")}"
      end

      sections << "Their question: #{question}"
      sections.join("\n\n")
    end
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

      raise upstream_error(response) unless response.ok?

      parse(response.body)
    end

    # Google returns the useful part — which quota was hit, and how long to wait —
    # in the body, not the status line. Without pulling it out, a 429 for the
    # daily cap is indistinguishable from a 429 for a burst, and the log says
    # neither.
    #
    # Only the diagnostics are logged. The prompt carries the document text, and
    # that must never reach a log file (R9.3).
    def upstream_error(response)
      detail = parse_error_body(response.body)
      details = Array(detail&.dig("details"))
      quota = details.flat_map { |d| Array(d["violations"]) }.filter_map { |v| v["quotaId"] }.first
      retry_after = details.filter_map { |d| d["retryDelay"] }.first

      Rails.logger.error(
        "[gemini] request failed " \
        "status=#{response.status} quota=#{quota || 'none'} " \
        "retry_after=#{retry_after || 'none'} " \
        "message=#{detail&.dig('message').to_s.truncate(200).inspect}"
      )

      ProcessingError::ServiceUnavailable.new(
        [ "http #{response.status}", quota, retry_after ].compact.join(" ")
      )
    end

    def parse_error_body(body)
      JSON.parse(body.to_s)["error"]
    rescue JSON::ParserError
      nil
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
