# Builds a short summary of a document from the passages that describe it.
#
# The document itself is never sent. A generic-anchor query retrieves the few
# passages that read like an overview, and only those go to the model — which is
# what makes summarising a 140-page document cost about the same as summarising
# a five-page one.
class DocumentSummarizer
  BULLETS = 3..5

  SCHEMA = {
    type: "OBJECT",
    properties: {
      title: { type: "STRING", nullable: true },
      bullets: { type: "ARRAY", items: { type: "STRING" } }
    },
    required: %w[bullets]
  }.freeze

  PROMPT = <<~PROMPT.freeze
    Below are a few passages taken from a longer document. They were selected
    because they read like the parts where a document explains what it is.

    Write between three and five short bullet points saying what this document is
    and what it covers.

    Rules:
    - Use only what the passages say. You have not seen the rest of the document.
    - Plain words, short sentences. No jargon.
    - Do not guess at anything the passages do not state, and do not pad the list
      to reach five points.
    - Also suggest a short title for the document if the passages make one
      obvious, and null if they do not.
  PROMPT

  Summary = Struct.new(:title, :bullets, keyword_init: true)

  def initialize(document, client: GeminiClient.new)
    @document = document
    @client = client
  end

  def call
    passages = ChunkRetriever.new(@document, client: @client).anchor_passages
    raise ProcessingError::Unreadable if passages.empty?

    result = @client.generate(prompt_for(passages), schema: SCHEMA)
    bullets = Array(result["bullets"]).map(&:to_s).reject(&:blank?)
    raise ProcessingError::ServiceUnavailable, "no bullets returned" if bullets.empty?

    Summary.new(title: result["title"].presence, bullets: bullets.first(BULLETS.max))
  end

  private
    def prompt_for(passages)
      body = passages.each_with_index.map do |chunk, i|
        "Passage #{i + 1} (#{chunk.location}):\n#{chunk.content}"
      end.join("\n\n")

      "#{PROMPT}\n\n#{body}"
    end
end
