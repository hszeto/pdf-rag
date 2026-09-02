# One question, one answer, and the rule about when the expensive path is
# allowed.
#
# The cost model for this app lives here: the summary is what goes over the wire
# for an ordinary question, and the full document only when the summary genuinely
# did not cover it — at most once per question (R6.1, R6.4). Putting that in a
# service rather than the controller keeps it testable and keeps the controller
# from quietly growing a second retry later.
class QuestionAnswerer
  # A "turn" is one message. Six keeps the tail of the conversation without
  # letting cost creep upward as the chat gets longer.
  HISTORY_TURNS = 6

  MAX_QUESTION_LENGTH = 500

  def initialize(session, client: GeminiClient.new)
    @session = session
    @client = client
  end

  def call(question)
    question = question.to_s.strip
    raise ProcessingError::EmptyQuestion if question.blank?

    question = question.truncate(MAX_QUESTION_LENGTH)
    answer = ask(question, @session.plain_summary)

    # The one permitted retry. Anything beyond this and the cheap-by-default
    # design stops being cheap.
    answer = ask(question, @session.full_text) if retry_against_full_text?(answer)

    record(question, answer.text)
    answer.text
  end

  private
    def ask(question, context)
      @client.answer(
        question: question,
        context: context.to_s,
        history: recent_history,
        phone: @session.field(:customer_service_phone)
      )
    end

    def retry_against_full_text?(answer)
      return false if answer.found?

      # Nothing to retry against if the summary is all we have.
      @session.full_text.present? && @session.full_text != @session.plain_summary
    end

    def recent_history = @session.chat_history.last(HISTORY_TURNS)

    def record(question, answer)
      @session.add_turn("user", question)
      @session.add_turn("assistant", answer)
      SessionCache.write(@session)
    end
end
