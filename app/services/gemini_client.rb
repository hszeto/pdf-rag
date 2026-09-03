require "net/http"

# Talks to Gemini.
#
# The transport is injected so payloads can be asserted and every failure mode
# driven without a network. That is not stylistic: this project has no mocking
# library, so a seam is the only way to test any of it. It also keeps the calls
# inside a plain service object, which is what lets a background job wrap them.
#
# The generation and embedding calls themselves arrive with the checkpoints that
# need them; what lives here is the request, response and error handling they all
# share.
class GeminiClient
  MODEL = "gemini-2.5-flash".freeze
  EMBEDDING_MODEL = "gemini-embedding-001".freeze
  EMBEDDING_DIMENSIONS = 3072
  BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models".freeze

  # Thinking is off by default. It is on in the API unless disabled, and a
  # trivial call measured 21 tokens with it versus 6 without. Thinking tokens
  # also count against max_output_tokens, so leaving it on with a tight ceiling
  # returns an empty response that reads like a bug.
  THINKING_BUDGET = 0
  MAX_OUTPUT_TOKENS = 2048
  TEMPERATURE = 0.1

  # Swapped wholesale in tests. This project has no mocking library, so the seam
  # is an explicit setting rather than a stubbing DSL. The test suite replaces it
  # with one that refuses to make a call, so a test that forgets a stub fails
  # loudly instead of quietly reaching the live API.
  mattr_accessor :transport_factory, default: -> { NetHttpTransport.new }

  def initialize(transport: nil, api_key: nil)
    @transport = transport || transport_factory.call
    @api_key = api_key || Rails.application.credentials.gemini_api_key
  end


  # The API's hard limit, confirmed by its own 400 response rather than
  # inferred: "at most 100 requests can be in one batch". This is what makes the
  # free tier viable — a 160-page document is a couple of requests rather than
  # a couple of hundred.
  MAX_EMBEDDING_BATCH = 100

  # Returns one vector per text, in the order given.
  def embed(texts)
    texts = Array(texts)
    return [] if texts.empty?

    EmbeddingBatches.for(texts).flat_map { |batch| embed_batch(batch) }
  end


  # A generation call that returns JSON matching a schema. Structured output is
  # what keeps prose and code fences out of the response, so the caller parses a
  # document rather than guessing at one.
  def generate(prompt, schema:)
    body = post("#{MODEL}:generateContent", {
      contents: [ { parts: [ { text: prompt } ] } ],
      generationConfig: generation_config.merge(
        responseMimeType: "application/json",
        responseSchema: schema
      )
    })

    text = body.dig("candidates", 0, "content", "parts", 0, "text")

    # An overloaded model answers 200 with no candidate, no finishReason and no
    # error status. Observed live. Without this it becomes a confusing nil chase
    # rather than a message someone can act on.
    raise ProcessingError::ServiceUnavailable, "empty response" if text.blank?

    JSON.parse(text)
  rescue JSON::ParserError => e
    raise ProcessingError::ServiceUnavailable, "unparseable generation: #{e.message}"
  end

  private
    def embed_batch(texts)
      body = post("#{EMBEDDING_MODEL}:batchEmbedContents", {
        requests: texts.map do |text|
          { model: "models/#{EMBEDDING_MODEL}", content: { parts: [ { text: text } ] } }
        end
      })

      vectors = Array(body["embeddings"]).map { |embedding| embedding["values"] }

      # Vectors are matched to chunks by position, so a short or reordered
      # response would attach the wrong passage's meaning to a chunk — a silent
      # corruption that would surface much later as retrieval simply being bad.
      unless vectors.length == texts.length && vectors.all? { |v| v&.length == EMBEDDING_DIMENSIONS }
        raise ProcessingError::ServiceUnavailable,
          "embedding response did not match the request: asked for #{texts.length}, " \
          "got #{vectors.length} vectors"
      end

      vectors
    end

    def generation_config
      {
        temperature: TEMPERATURE,
        maxOutputTokens: MAX_OUTPUT_TOKENS,
        thinkingConfig: { thinkingBudget: THINKING_BUDGET }
      }
    end

    def post(path, payload)
      raise ProcessingError::ServiceUnavailable, "no api key configured" if @api_key.blank?

      response = @transport.call(
        url: "#{BASE_URL}/#{path}",
        # The key travels as a header rather than a query parameter so it never
        # reaches a URL, a referrer, or an access log.
        headers: { "content-type" => "application/json", "x-goog-api-key" => @api_key },
        body: payload.to_json
      )

      raise upstream_error(response) unless response.ok?

      JSON.parse(response.body.to_s)
    rescue JSON::ParserError => e
      raise ProcessingError::ServiceUnavailable, "unparseable response: #{e.message}"
    end

    # Google returns the useful part — which quota was hit, and how long to wait —
    # in the body, not the status line. Without pulling it out, a 429 for the
    # daily cap is indistinguishable from a 429 for a burst, and the log says
    # neither.
    #
    # Only the diagnostics are logged. The prompt carries document text, and that
    # must never reach a log file.
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
end
