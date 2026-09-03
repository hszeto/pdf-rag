# Embeds one batch of a document's passages.
#
# Per batch rather than per document so that a failure — an overloaded model, a
# rate limit — costs one batch instead of the whole thing, and so no single
# worker is held for the length of a long document.
#
# A batch is sized to be one request, but the client re-checks and will split an
# oversized one rather than send something the API refuses. In that case a
# failure retries the whole job, re-paying for any request that had succeeded —
# which is why the sizing happens up front rather than being left to chance.
class EmbedChunkBatchJob < ApplicationJob
  queue_as :default

  # Rate limits are the expected case here, not an exception: the free tier
  # rejects on a per-minute token budget. Retrying is the whole reason batches
  # are separate jobs — failing the document on a transient 429 would throw away
  # the work that already succeeded.
  #
  # The wait is deliberately flat and roughly one window long. Rails' polynomial
  # backoff would space six attempts across 38 minutes, which is most of the
  # hour a document is kept, to wait out a budget that resets every sixty
  # seconds. Five attempts at ~75s covers six minutes and matches the shape of
  # the limit being waited on.
  RETRY_WAIT = 75.seconds

  retry_on ProcessingError::ServiceUnavailable, wait: RETRY_WAIT, attempts: 5 do |job, error|
    document = Document.find_by(id: job.arguments.first)
    Rails.logger.error("[embed] document=#{job.arguments.first} giving up: #{error.message}")
    document&.fail!(error.user_message)
  end

  def perform(document_id, chunk_ids)
    document = Document.live.find_by(id: document_id)
    return if document.nil? || !document.embedding?

    # Materialised once, in a stable order: vectors come back positionally, so
    # re-querying between building the request and saving the response could
    # attach a passage's meaning to the wrong chunk.
    chunks = document.chunks.where(id: chunk_ids, embedding: nil).ordered.to_a
    return finish(document) if chunks.empty?

    vectors = GeminiClient.new.embed(chunks.map(&:content))

    DocumentChunk.transaction do
      chunks.zip(vectors).each { |chunk, vector| chunk.update_column(:embedding, vector) }
    end

    finish(document)
  end

  private
    # Whichever batch finds nothing left is the last one. The database already
    # knows when the work is done, so there is no counter to keep, nothing to
    # lock, and a retried batch reaches the same conclusion.
    def finish(document)
      return if document.chunks_awaiting_embedding.exists?

      document.update!(status: "ready")
      Rails.logger.info("[embed] document=#{document.id} ready with #{document.chunks.count} passages")
    end
end
