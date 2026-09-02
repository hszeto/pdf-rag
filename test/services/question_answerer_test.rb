require "test_helper"

class QuestionAnswererTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @session = SessionCache.create
    @session.status = "extracted"
    @session.plain_summary = "Your deductible is $1,500. A doctor visit costs $20."
    @session.full_text = "FULL DOCUMENT TEXT including dental cleanings at $0."
    @session.structured_fields[:customer_service_phone] = "1-800-555-0142"
    SessionCache.write(@session)
  end

  # AC 15: the whole cost model rests on this. The document goes over the wire
  # once, at upload — never again on an ordinary question.
  test "an ordinary question sends the summary and never the full document" do
    fake = FakeGeminiTransport.new(answer_payload(found: true))

    answerer(fake).call("What is my deductible?")

    assert_equal 1, fake.call_count
    prompt = fake.prompt_for
    assert_includes prompt, "Your deductible is $1,500"
    assert_no_match(/FULL DOCUMENT TEXT/, prompt,
      "the full document must never be sent on the normal path")
  end

  # AC 16
  test "a question the summary does not cover retries once against the full text" do
    fake = FakeGeminiTransport.new(answer_payload(found: false), answer_payload(found: true))

    answerer(fake).call("Are dental cleanings covered?")

    assert_equal 2, fake.call_count
    assert_no_match(/FULL DOCUMENT TEXT/, fake.prompt_for(0), "the first call is the cheap one")
    assert_includes fake.prompt_for(1), "FULL DOCUMENT TEXT"
  end

  # AC 16: the expensive path is capped. If a second miss could trigger a second
  # retry, one bad summary would quietly undo the cost model.
  test "a second miss does not trigger a second retry" do
    fake = FakeGeminiTransport.new(answer_payload(found: false), answer_payload(found: false))

    answerer(fake).call("Are dental cleanings covered?")

    assert_equal 2, fake.call_count, "at most one fallback per question"
  end

  test "the answer from the fallback is what gets recorded" do
    fake = FakeGeminiTransport.new(
      answer_payload(found: false, answer: "I could not find that."),
      answer_payload(found: true, answer: "Dental cleanings cost you nothing.")
    )

    result = answerer(fake).call("Are dental cleanings covered?")

    assert_equal "Dental cleanings cost you nothing.", result
    assert_equal "Dental cleanings cost you nothing.", @session.chat_history.last[:content]
  end

  test "no retry when there is no full text to retry against" do
    @session.full_text = nil
    fake = FakeGeminiTransport.new(answer_payload(found: false))

    answerer(fake).call("Anything?")

    assert_equal 1, fake.call_count
  end

  # AC 18
  test "both sides of the exchange are recorded, in order" do
    fake = FakeGeminiTransport.new(answer_payload(found: true, answer: "It is $1,500."))

    answerer(fake).call("What is my deductible?")

    assert_equal 2, @session.chat_history.length
    assert_equal [ "user", "assistant" ], @session.chat_history.map { |t| t[:role] }
    assert_equal "What is my deductible?", @session.chat_history.first[:content]
    assert_equal "It is $1,500.", @session.chat_history.last[:content]
  end

  test "the exchange survives in the cache" do
    fake = FakeGeminiTransport.new(answer_payload(found: true))

    answerer(fake).call("What is my deductible?")

    assert_equal 2, SessionCache.find(@session.session_id).chat_history.length
  end

  # AC 15: without a cap, every question costs more than the last.
  test "only the most recent turns are sent" do
    12.times { |i| @session.add_turn(i.even? ? "user" : "assistant", "old message #{i}") }
    fake = FakeGeminiTransport.new(answer_payload(found: true))

    answerer(fake).call("And now?")

    prompt = fake.prompt_for
    assert_includes prompt, "old message 11"
    assert_no_match(/old message 0\b/, prompt, "history must be trimmed, not sent whole")
    assert_operator prompt.scan(/old message/).length, :<=, QuestionAnswerer::HISTORY_TURNS
  end

  # R6.3
  test "the phone number is given to the model so it can offer it" do
    fake = FakeGeminiTransport.new(answer_payload(found: true))

    answerer(fake).call("Who do I call?")

    assert_includes fake.prompt_for, "1-800-555-0142"
  end

  test "the model is told to answer only from what it is given" do
    fake = FakeGeminiTransport.new(answer_payload(found: true))

    answerer(fake).call("What is my deductible?")

    prompt = fake.prompt_for
    assert_match(/only from the information given/i, prompt)
    assert_match(/never use general knowledge/i, prompt)
  end

  test "an empty question is refused before any call" do
    fake = FakeGeminiTransport.new

    [ "", "   ", nil ].each do |blank|
      assert_raises(ProcessingError::EmptyQuestion) { answerer(fake).call(blank) }
    end

    assert_equal 0, fake.call_count
  end

  test "an absurdly long question is truncated rather than sent whole" do
    fake = FakeGeminiTransport.new(answer_payload(found: true))

    answerer(fake).call("a" * 5_000)

    assert_operator fake.prompt_for.scan(/a{50,}/).first.to_s.length, :<=,
      QuestionAnswerer::MAX_QUESTION_LENGTH
  end

  test "a failure mid-conversation leaves the earlier history intact" do
    answerer(FakeGeminiTransport.new(answer_payload(found: true))).call("First question?")

    assert_raises(ProcessingError::ServiceUnavailable) do
      answerer(FakeGeminiTransport.new([ 503, "down" ])).call("Second question?")
    end

    assert_equal 2, SessionCache.find(@session.session_id).chat_history.length
  end

  private
    def answerer(transport)
      QuestionAnswerer.new(@session, client: GeminiClient.new(transport: transport, api_key: "k"))
    end

    def answer_payload(found:, answer: "Here is what your plan says.")
      { "answer" => answer, "found_in_summary" => found }
    end
end
