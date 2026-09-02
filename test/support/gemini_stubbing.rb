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
end
