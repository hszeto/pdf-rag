require "test_helper"

class ChatTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  test "asking a question shows the exchange on the plan screen" do
    upload_document
    ask "What is my deductible?", answer: "Your deductible is $1,500 a year."

    assert_select "li", /You asked/
    assert_includes response.body, "What is my deductible?"
    assert_includes response.body, "Your deductible is $1,500 a year."
  end

  # AC 18
  test "history builds up across turns" do
    upload_document
    ask "First question?", answer: "First answer."
    ask "Second question?", answer: "Second answer."

    body = response.body
    [ "First question?", "First answer.", "Second question?", "Second answer." ].each do |text|
      assert_includes body, text
    end
    assert_equal 4, SessionCache.find(session_id).chat_history.length
  end

  # AC 18
  test "history disappears with the session" do
    upload_document
    ask "What is my deductible?", answer: "It is $1,500."
    id = session_id

    travel(SessionCache::TTL + 1.second) do
      get root_path

      assert_response :success
      assert_nil SessionCache.find(id)
      assert_no_match(/It is \$1,500/, response.body)
    end
  end

  test "the example questions are offered before any have been asked" do
    upload_document

    assert_select "button", text: /copay for a doctor visit/i
    assert_select "button", text: /Who do I call with questions/i
  end

  test "an example question can be asked by pressing it" do
    upload_document

    stub_gemini("answer" => "You pay $20.", "found_in_summary" => true) do
      post messages_path, params: { question: "What's my copay for a doctor visit?" }
    end
    follow_redirect!

    assert_includes response.body, "You pay $20."
  end

  # R7.5: a failed question must not cost the reader their plan screen.
  test "a failure while asking keeps the plan on screen" do
    upload_document

    stub_gemini([ 503, "down" ]) do
      post messages_path, params: { question: "Anything?" }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /trouble reading documents/i
    assert_select "h1", "Your plan"
    assert_includes response.body, "$1,500", "the extracted facts must still be there"
  end

  test "an empty question is refused without losing the plan" do
    upload_document

    stub_gemini do
      post messages_path, params: { question: "   " }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /type a question first/i
    assert_select "h1", "Your plan"
  end

  test "asking without a document says so rather than erroring" do
    get root_path

    stub_gemini do |fake|
      post messages_path, params: { question: "What is my deductible?" }

      assert_equal 0, fake.call_count
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /add your insurance document first/i
  end

  test "asking after the session expired returns to the landing screen" do
    upload_document

    travel(SessionCache::TTL + 1.second) do
      stub_gemini do |fake|
        post messages_path, params: { question: "Anything?" }

        assert_equal 0, fake.call_count
      end

      assert_select "[role=alert]", /add your insurance document first/i
    end
  end

  test "asking refreshes the idle timer" do
    upload_document
    id = session_id

    travel(4.minutes) { ask "Still here?", answer: "Yes." }

    travel(8.minutes) { assert_not_nil SessionCache.find(id) }
  end

  # R7.6 on the chat screen too.
  test "the grounding note stays visible alongside the conversation" do
    upload_document
    ask "What is my deductible?", answer: "It is $1,500."

    assert_select "aside", /comes from the document you added/i
  end

  private
    def upload_document
      upload_and_analyze
      get root_path
    end

    def ask(question, answer:)
      stub_gemini("answer" => answer, "found_in_summary" => true) do
        post messages_path, params: { question: question }
      end
      follow_redirect!
    end
end
