# Answers one question from the passages most relevant to it.
#
# The document is never sent — not on any path, and unlike the previous
# incarnation of this app there is no full-text fallback to reach for. If the
# retrieved passages do not contain the answer, the honest response is to say so.
class QuestionAnswerer
  # How many passages an answer is built from. Enough to cover a fact stated in
  # more than one place, few enough that the model cannot wander.
  PASSAGES = 3

  MAX_QUESTION_LENGTH = 500

  SCHEMA = {
    type: "OBJECT",
    properties: {
      answer: { type: "STRING" },
      found_in_context: { type: "BOOLEAN" },
      # Which of the numbered passages the answer actually rests on, so a reader
      # can go and check rather than taking it on trust.
      used_passages: { type: "ARRAY", items: { type: "INTEGER" } }
    },
    required: %w[answer found_in_context]
  }.freeze

  PROMPT = <<~PROMPT.freeze
    Below are passages taken from one document, followed by a question about it.

    Answer using only those passages. They are the only thing you know about this
    document, and you have not seen the rest of it.

    Rules:
    - Never answer from general knowledge. Documents differ, and a confident
      wrong answer is worse than no answer.
    - If the passages do not contain the answer, set found_in_context to false
      and say plainly that this part of the document does not cover it.
    - List in used_passages the numbers of the passages your answer rests on.
    - Short sentences. Plain words. No jargon.
  PROMPT

  Answer = Struct.new(:text, :found, :citations, keyword_init: true) do
    def found? = found
  end

  def initialize(document, client: GeminiClient.new)
    @document = document
    @client = client
  end

  def call(question)
    question = question.to_s.strip
    raise ProcessingError::EmptyQuestion if question.blank?

    question = question.truncate(MAX_QUESTION_LENGTH)
    passages = ChunkRetriever.new(@document, client: @client).nearest(question, limit: PASSAGES)
    raise ProcessingError::Unreadable if passages.empty?

    result = @client.generate(prompt_for(question, passages), schema: SCHEMA)
    answer = build_answer(result, passages)

    record(question, answer)
    answer
  end

  private
    def prompt_for(question, passages)
      numbered = passages.each_with_index.map do |chunk, i|
        "Passage #{i + 1} (#{chunk.location}):\n#{chunk.content}"
      end.join("\n\n")

      "#{PROMPT}\n\n#{numbered}\n\nQuestion: #{question}"
    end

    # Citations are resolved from passage numbers back to their place in the
    # document. A model naming passage 7 when it was given three is ignored
    # rather than trusted.
    def build_answer(result, passages)
      used = Array(result["used_passages"]).filter_map do |number|
        passages[number.to_i - 1] if number.to_i.between?(1, passages.length)
      end

      Answer.new(
        text: result["answer"].to_s,
        found: result["found_in_context"] == true,
        citations: used.map(&:location).uniq
      )
    end

    def record(question, answer)
      Message.transaction do
        @document.messages.create!(role: "user", content: question)
        @document.messages.create!(
          role: "assistant", content: answer.text, citations: answer.citations
        )
      end
    end
end
