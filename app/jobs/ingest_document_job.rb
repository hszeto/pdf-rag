# Reads a stored document and turns it into retrievable passages.
#
# Only the id crosses the queue; the file is in Active Storage and the text never
# becomes a job argument.
#
# Embedding is deliberately *not* done here. This job creates chunk rows with
# empty embeddings and hands the expensive part to per-batch jobs, so a failure
# part-way costs one batch rather than the whole document.
class IngestDocumentJob < ApplicationJob
  queue_as :default

  def perform(document_id)
    document = Document.live.find_by(id: document_id)
    # Expired, deleted, or already handled while this sat in the queue.
    return if document.nil? || !document.pending?

    document.update!(status: "extracting")

    pages = extract(document)
    text = pages.map(&:text).join("\n")
    document.update!(content_hash: Digest::SHA256.hexdigest(text))

    return if reuse_existing_chunks(document)

    build_chunks(document, pages)
    document.update!(status: "embedding")
  rescue ProcessingError => e
    Rails.logger.error("[ingest] document=#{document_id} failed #{e.class.name.demodulize}: #{e.message}")
    document&.fail!(e.user_message)
  end

  private
    def extract(document)
      document.file.open do |file|
        PdfExtractionService.new(file).pages
      end
    end

    # D6: the same document uploaded twice costs one set of embeddings, not two.
    # Chunks are copied rather than shared so that deleting one document can
    # never strand another's passages.
    def reuse_existing_chunks(document)
      twin = Document.live.ready
                     .where(content_hash: document.content_hash)
                     .where.not(id: document.id)
                     .first
      return false if twin.nil?

      rows = twin.chunks.ordered.map do |chunk|
        {
          document_id: document.id, content: chunk.content, position: chunk.position,
          page: chunk.page, embedding: chunk.embedding,
          created_at: Time.current, updated_at: Time.current
        }
      end
      DocumentChunk.insert_all!(rows) if rows.any?

      document.update!(status: "ready", summary: twin.summary, title: twin.title)
      Rails.logger.info("[ingest] document=#{document.id} reused #{rows.length} chunks from #{twin.id}")
      true
    end

    def build_chunks(document, pages)
      rows = TextChunker.new(pages).chunks.map do |chunk|
        {
          document_id: document.id, content: chunk.content, position: chunk.position,
          page: chunk.page, created_at: Time.current, updated_at: Time.current
        }
      end
      raise ProcessingError::Unreadable if rows.empty?

      DocumentChunk.insert_all!(rows)
    end
end
