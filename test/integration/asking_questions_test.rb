require "test_helper"

class AskingQuestionsTest < ActionDispatch::IntegrationTest
  setup { @document = searchable_document }

  test "asking a question shows the exchange on the document page" do
    ask "What is the deductible?", answer: "It is $1,500 a year."

    assert_select "li", /User/
    assert_includes response.body, "What is the deductible?"
    assert_includes response.body, "It is $1,500 a year."
  end

  # AC 16
  # D4 and D5: the reader's words on the right, the answer on the left, each
  # named in text so the distinction is not carried by position alone (R2.6).
  test "the question sits right and the answer sits left, each named" do
    ask "What is the deductible?", answer: "It is $1,500 a year."

    assert_select "li.justify-end", /User/
    assert_select "li.justify-start", /AI/
  end

  test "no avatars and no timestamps appear in the exchange" do
    ask "What is the deductible?", answer: "It is $1,500 a year."

    assert_select "li img", count: 0
    assert_select "li time", count: 0
  end

  # R2.3: a growing page should not send the reader back to the top.
  test "asking lands the reader on the answer" do
    ask "What is the deductible?", answer: "It is $1,500 a year."

    newest = @document.messages.ordered.last
    assert_equal "assistant", newest.role
    assert_select "li##{ActionView::RecordIdentifier.dom_id(newest)}"
  end

  test "a document with no questions yet invites one" do
    get document_path(@document)

    assert_select "p", /No questions yet/
    assert_select "label", /Type your question/
  end

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

  # The browser asks for a stream, so the answer is appended to the page the
  # reader is already looking at rather than replacing it.
  test "the answer arrives as a stream that appends, not a redirect" do
    stream "What is the deductible?", answer: "It is $1,500."

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/action="append" target="messages"/, response.body)
    assert_match(/It is \$1,500\./, response.body)
  end

  test "the stream carries both turns of the exchange" do
    stream "What is the deductible?", answer: "It is $1,500."

    assert_equal 2, response.body.scan(/action="append" target="messages"/).length
    assert_match(/What is the deductible\?/, response.body)
  end

  # Replacing the form is what clears the question that was just asked.
  test "the stream replaces the form so the field comes back empty" do
    stream "What is the deductible?", answer: "It is $1,500."

    assert_match(/action="replace" target="ask-form"/, response.body)
  end

  # The empty-state line has to go the moment there is something to show.
  test "the stream removes the no-questions notice" do
    stream "First question?", answer: "First answer."

    assert_match(/action="remove" target="no-questions"/, response.body)
  end

  test "a failed question still answers with a page rather than a stream" do
    stub_gemini(gemini_embeddings(1), [ 503, "down" ]) do
      post document_messages_path(@document), params: { question: "Second?" }, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_equal "text/html", response.media_type
    assert_select "[role=alert]", /trouble reading documents/i
  end

  private
    def stream(question, answer:, found: true, used: [ 1 ])
      stub_gemini(gemini_embeddings(1), gemini_answer(text: answer, found: found, used: used)) do
        post document_messages_path(@document), params: { question: question }, as: :turbo_stream
      end
    end

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
