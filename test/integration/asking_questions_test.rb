require "test_helper"

class AskingQuestionsTest < ActionDispatch::IntegrationTest
  setup { @document = searchable_document }

  test "asking a question shows the exchange on the document page" do
    ask "What is the deductible?", answer: "It is $1,500 a year."

    assert_select "li", /You asked/
    assert_includes response.body, "What is the deductible?"
    assert_includes response.body, "It is $1,500 a year."
  end

  # AC 16
  test "an answer shows where in the document it came from" do
    ask "What is the deductible?", answer: "It is $1,500.", used: [ 1, 2 ]

    assert_select "p", /From page \d+ and page \d+ of your document/
  end

  test "an answer with no citations does not claim one" do
    ask "Anything?", answer: "That is not covered here.", found: false, used: []

    assert_select "p", { text: /of your document/, count: 0 }
  end

  test "history builds up across questions" do
    ask "First question?", answer: "First answer."
    ask "Second question?", answer: "Second answer."

    [ "First question?", "First answer.", "Second question?", "Second answer." ].each do |text|
      assert_includes response.body, text
    end
    assert_equal 4, @document.messages.count
  end

  # A failed question must not cost the reader their document or their history.
  test "a failure keeps the document and its history on screen" do
    ask "First question?", answer: "First answer."

    stub_gemini(gemini_embeddings(1), [ 503, "down" ]) do
      post document_messages_path(@document), params: { question: "Second?" }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /trouble reading documents/i
    assert_includes response.body, "First answer.", "the earlier exchange must survive"
  end

  test "an empty question is refused without losing the page" do
    stub_gemini do
      post document_messages_path(@document), params: { question: "   " }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /type a question first/i
    assert_select "h1"
  end

  test "a document still being read cannot be asked about yet" do
    @document.update!(status: "embedding")

    stub_gemini do |fake|
      post document_messages_path(@document), params: { question: "Anything?" }

      assert_equal 0, fake.call_count
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /still reading/i
  end

  test "asking about an expired document sends you back to the start" do
    @document.update!(expires_at: 1.minute.ago)

    stub_gemini do |fake|
      post document_messages_path(@document), params: { question: "Anything?" }

      assert_equal 0, fake.call_count
    end

    assert_redirected_to root_path
  end

  test "asking about a document that never existed does not blow up" do
    stub_gemini do
      post document_messages_path(document_id: 999_999), params: { question: "Anything?" }
    end

    assert_redirected_to root_path
  end

  private
    def ask(question, answer:, found: true, used: [ 1 ])
      stub_gemini(gemini_embeddings(1), gemini_answer(text: answer, found: found, used: used)) do
        post document_messages_path(@document), params: { question: question }
      end
      follow_redirect!
    end

    def searchable_document
      Document.create!(status: "ready", title: "doc.pdf", summary: "A summary.").tap do |document|
        6.times do |i|
          document.chunks.create!(
            content: "passage #{i} about deductibles and copays " * 15,
            position: i, page: i + 1,
            embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { rand }
          )
        end
      end
    end
end
