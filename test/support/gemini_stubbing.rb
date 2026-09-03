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

  # A batchEmbedContents response with one vector per request, so a test does not
  # have to hand-build 100 vectors of 3072 floats.
  def gemini_embeddings(count, dimensions: GeminiClient::EMBEDDING_DIMENSIONS)
    { "embeddings" => Array.new(count) { { "values" => Array.new(dimensions) { 0.01 } } } }
  end

  # A generateContent response carrying a JSON payload, which the API nests
  # inside candidates/content/parts as a string.
  def gemini_generation(payload)
    { "candidates" => [ { "content" => { "parts" => [ { "text" => payload.to_json } ] } } ] }
  end

  # A summary response, overridable per test.
  def gemini_summary(bullets: [ "It is a health plan document.", "It lists what you pay." ], title: "A Plan")
    gemini_generation({ "title" => title, "bullets" => bullets })
  end
end
