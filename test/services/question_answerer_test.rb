require "test_helper"

class QuestionAnswererTest < ActiveSupport::TestCase
  setup { @document = searchable_document }

  # AC 14. Unlike the previous version of this app there is no full-text
  # fallback to reach for: if the passages do not hold the answer, saying so is
  # the answer.
  test "the document is never sent, only the passages retrieved" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer)

    ask(fake, "What is the deductible?")

    prompt = fake.calls.last[:body].dig("contents", 0, "parts", 0, "text")
    included = @document.chunks.count { |c| prompt.include?(c.content) }
    assert_operator included, :<=, QuestionAnswerer::PASSAGES
    assert_operator included, :<, @document.chunks.count
  end

  test "costs one embedding call and one generation call" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer)

    ask(fake, "What is the deductible?")

    assert_equal 2, fake.call_count
  end

  test "the question is what gets embedded" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer)

    ask(fake, "What is my specialist copay?")

    embedded = fake.calls.first[:body].dig("requests", 0, "content", "parts", 0, "text")
    assert_equal "What is my specialist copay?", embedded
  end

  test "the model is told to answer only from the passages" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer)

    ask(fake, "Anything?")

    prompt = fake.calls.last[:body].dig("contents", 0, "parts", 0, "text")
    assert_match(/only those passages/i, prompt)
    assert_match(/never answer from general knowledge/i, prompt)
  end

  # AC 16
  test "an answer carries where in the document it came from" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer(used: [ 1, 2 ]))

    answer = ask(fake, "What is the deductible?")

    assert_equal 2, answer.citations.length
    assert answer.citations.all? { |c| c.match?(/page \d+/) }
  end

  # A model naming a passage it was not given must not produce a citation.
  test "a citation outside the passages given is discarded" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer(used: [ 1, 99, 0, -3 ]))

    answer = ask(fake, "What is the deductible?")

    assert_equal 1, answer.citations.length
  end

  # AC 15
  test "a question the passages do not cover is reported as unanswered" do
    fake = FakeGeminiTransport.new(
      gemini_embeddings(1),
      gemini_answer(text: "This part of the document does not cover that.", found: false, used: [])
    )

    answer = ask(fake, "What is the capital of France?")

    assert_not answer.found?
    assert_empty answer.citations
    assert_match(/does not cover/i, answer.text)
  end

  # R6.5
  test "both sides of the exchange are recorded, in order" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer(text: "It is $1,500."))

    ask(fake, "What is the deductible?")

    messages = @document.messages.ordered
    assert_equal %w[user assistant], messages.map(&:role)
    assert_equal "What is the deductible?", messages.first.content
    assert_equal "It is $1,500.", messages.last.content
  end

  test "citations are stored with the answer" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer(used: [ 2 ]))

    ask(fake, "What is the deductible?")

    assert_equal 1, @document.messages.ordered.last.citations.length
  end

  test "history builds up across questions" do
    2.times do |i|
      fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer(text: "Answer #{i}."))
      ask(fake, "Question #{i}?")
    end

    assert_equal 4, @document.messages.count
  end

  test "an empty question is refused before any call" do
    fake = FakeGeminiTransport.new

    [ "", "   ", nil ].each do |blank|
      assert_raises(ProcessingError::EmptyQuestion) { ask(fake, blank) }
    end

    assert_equal 0, fake.call_count
  end

  test "an absurdly long question is truncated rather than sent whole" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), gemini_answer)

    ask(fake, "a" * 5_000)

    embedded = fake.calls.first[:body].dig("requests", 0, "content", "parts", 0, "text")
    assert_operator embedded.length, :<=, QuestionAnswerer::MAX_QUESTION_LENGTH + 3
  end

  test "a document with nothing embedded cannot be asked about" do
    @document.chunks.update_all(embedding: nil)
    fake = FakeGeminiTransport.new(gemini_embeddings(1))

    assert_raises(ProcessingError::Unreadable) { ask(fake, "Anything?") }
  end

  test "a failed answer records nothing" do
    fake = FakeGeminiTransport.new(gemini_embeddings(1), [ 503, "down" ])

    assert_raises(ProcessingError::ServiceUnavailable) { ask(fake, "Anything?") }

    assert_equal 0, @document.messages.count
  end

  private
    def ask(transport, question)
      QuestionAnswerer.new(@document, client: GeminiClient.new(transport: transport, api_key: "k")).call(question)
    end

    def searchable_document
      Document.create!(status: "ready", title: "doc.pdf").tap do |document|
        10.times do |i|
          document.chunks.create!(
            content: "passage #{i} about deductibles and copays and coverage " * 15,
            position: i, page: i + 1,
            embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { rand }
          )
        end
      end
    end
end
