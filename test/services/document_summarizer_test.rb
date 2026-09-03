require "test_helper"

class DocumentSummarizerTest < ActiveSupport::TestCase
  setup { @document = embedded_document }

  # AC 13. The point of the whole architecture: a 140-page document costs about
  # the same to summarise as a five-page one, because neither is sent.
  test "the document itself is never sent" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_summary)

    summarize(fake)

    generation = fake.calls.last[:body]
    prompt = generation.dig("contents", 0, "parts", 0, "text")
    sent = @document.chunks.count { |c| prompt.include?(c.content) }
    assert_operator sent, :<, @document.chunks.count, "every passage was sent"
    assert_operator prompt.length, :<, @document.chunks.sum { |c| c.content.length },
      "the prompt should be a fraction of the document"
  end

  test "only the retrieved passages reach the prompt" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_summary)

    summarize(fake)

    prompt = fake.calls.last[:body].dig("contents", 0, "parts", 0, "text")
    included = @document.chunks.count { |c| prompt.include?(c.content) }
    assert_operator included, :<=, ChunkRetriever::SUMMARY_PASSAGES
    assert_operator included, :>=, 1
  end

  # R5.1: the query is about a document's shape, not its subject.
  test "the anchor query asks where a document explains itself" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_summary)

    summarize(fake)

    embedded_query = fake.calls.first[:body].dig("requests", 0, "content", "parts", 0, "text")
    assert_match(/executive summary/i, embedded_query)
    assert_match(/conclusion/i, embedded_query)
  end

  test "costs one embedding call and one generation call" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_summary)

    summarize(fake)

    assert_equal 2, fake.call_count
  end

  test "returns the bullets and the suggested title" do
    fake = FakeGeminiTransport.new(
      gemini_embeddings(1),
      gemini_summary(bullets: [ "One.", "Two.", "Three." ], title: "Benefits Guide")
    )

    summary = summarize(fake)

    assert_equal [ "One.", "Two.", "Three." ], summary.bullets
    assert_equal "Benefits Guide", summary.title
  end

  test "never returns more than five bullets" do
    fake = FakeGeminiTransport.new(
      gemini_embeddings(1),
      gemini_summary(bullets: Array.new(9) { |i| "Point #{i}." })
    )

    assert_equal 5, summarize(fake).bullets.length
  end

  test "blank bullets are discarded" do
    fake = FakeGeminiTransport.new(
      gemini_embeddings(1), gemini_summary(bullets: [ "Real.", "", "  " ])
    )

    assert_equal [ "Real." ], summarize(fake).bullets
  end

  test "a response with no usable bullets is a service error" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_summary(bullets: []))

    assert_raises(ProcessingError::ServiceUnavailable) { summarize(fake) }
  end

  test "a document with nothing embedded cannot be summarised" do
    @document.chunks.update_all(embedding: nil)
    fake = FakeGeminiTransport.new(gemini_embeddings(1))

    assert_raises(ProcessingError::Unreadable) { summarize(fake) }
  end

  # R5.4: retrieval always returns its nearest matches, so a document with no
  # overview-like passages still gets summarised from whatever is closest.
  test "a document with no obvious overview is still summarised" do
    @document.chunks.update_all(content: "Clause 12.4 applies to prior authorisation only. " * 20)
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_summary)

    assert_equal 2, summarize(fake).bullets.length
  end

  private
    def summarize(transport)
      DocumentSummarizer.new(@document, client: GeminiClient.new(transport: transport, api_key: "k")).call
    end

    # Thirty realistically sized passages, so "the prompt is a fraction of the
    # document" is a meaningful claim rather than an artefact of a toy fixture.
    def embedded_document
      Document.create!(status: "summarizing", title: "doc.pdf").tap do |document|
        30.times do |i|
          body = "PAGEMARKER#{format('%03d', i)} " +
                 ("coverage costs and prior authorisation for benefit category #{i} " * 20)
          document.chunks.create!(
            content: body, position: i, page: i + 1,
            embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { rand }
          )
        end
      end
    end
end
