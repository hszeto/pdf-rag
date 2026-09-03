require "test_helper"

class GeminiEmbeddingTest < ActiveSupport::TestCase
  test "asks the embedding model at the batch endpoint" do
    fake = FakeGeminiTransport.new(gemini_embeddings(2))

    client(fake).embed([ "one", "two" ])

    assert_equal 1, fake.call_count
    assert_equal "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:batchEmbedContents",
      fake.calls.first[:url]
  end

  test "returns one vector per text, of the expected size" do
    vectors = client(FakeGeminiTransport.new(gemini_embeddings(3))).embed(%w[a b c])

    assert_equal 3, vectors.length
    assert vectors.all? { |v| v.length == GeminiClient::EMBEDDING_DIMENSIONS }
  end

  # AC 24. This is the assertion that keeps the free tier viable: the API caps a
  # batch at 100, so a long document is a handful of requests, not hundreds.
  test "a document-sized job is a handful of requests, not hundreds" do
    fake = FakeGeminiTransport.new(gemini_embeddings(100), gemini_embeddings(100), gemini_embeddings(50))

    vectors = client(fake).embed(Array.new(250) { |i| "chunk #{i}" })

    assert_equal 250, vectors.length
    assert_equal 3, fake.call_count, "250 chunks should cost 3 requests"
  end

  test "never exceeds the API's batch ceiling" do
    fake = FakeGeminiTransport.new(gemini_embeddings(100), gemini_embeddings(1))

    client(fake).embed(Array.new(101) { "x" })

    fake.calls.each do |call|
      assert_operator call[:body]["requests"].length, :<=, GeminiClient::MAX_EMBEDDING_BATCH
    end
  end

  test "sends nothing when there is nothing to embed" do
    fake = FakeGeminiTransport.new

    assert_empty client(fake).embed([])
    assert_equal 0, fake.call_count
  end

  # Vectors are matched to chunks positionally. A short response would attach one
  # passage's meaning to another — silent corruption that surfaces much later as
  # retrieval merely being bad, with nothing pointing at the cause.
  test "a response with fewer vectors than requested is refused" do
    fake = FakeGeminiTransport.new(gemini_embeddings(2))

    error = assert_raises(ProcessingError::ServiceUnavailable) do
      client(fake).embed(%w[a b c])
    end

    assert_match(/asked for 3, got 2/, error.message)
  end

  test "a response with wrongly sized vectors is refused" do
    fake = FakeGeminiTransport.new(gemini_embeddings(2, dimensions: 768))

    assert_raises(ProcessingError::ServiceUnavailable) { client(fake).embed(%w[a b]) }
  end

  test "an upstream failure surfaces as a friendly error" do
    fake = FakeGeminiTransport.new([ 429, "quota" ])

    error = assert_raises(ProcessingError::ServiceUnavailable) { client(fake).embed([ "a" ]) }

    assert_match(/trouble reading documents/i, error.user_message)
  end

  private
    def client(transport) = GeminiClient.new(transport: transport, api_key: "test-key")
end
