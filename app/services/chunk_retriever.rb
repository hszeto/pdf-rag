# Finds the passages of a document most likely to answer something.
#
# This is the piece that replaces sending the document to the model. Everything
# downstream — the summary, every answer — works from a handful of passages
# chosen here, which is why the whole document never goes over the wire.
class ChunkRetriever
  # How many passages a summary is built from. Enough to cover a document's
  # shape without becoming a long prompt.
  SUMMARY_PASSAGES = 5

  # Language that tends to sit near the parts of a document that describe the
  # whole of it. Nothing about this is domain-specific: it is a "where does this
  # document explain itself" query, not a question about the subject matter.
  GENERIC_ANCHOR = "executive summary, conclusion, abstract, overview, main findings, " \
                   "purpose, scope, key points".freeze

  def initialize(document, client: GeminiClient.new)
    @document = document
    @client = client
  end

  def nearest(query, limit:)
    return [] if limit < 1

    vector = @client.embed([ query ]).first
    return [] if vector.blank?

    by_similarity(vector, limit)
  end

  # The passages a summary should be built from (R5.1).
  def anchor_passages(limit: SUMMARY_PASSAGES) = nearest(GENERIC_ANCHOR, limit: limit)

  private
    def by_similarity(vector, limit)
      @document.chunks
               .embedded
               .nearest_neighbors(:embedding, vector, distance: "cosine")
               .limit(limit)
               .to_a
    end
end
