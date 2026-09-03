# Summarises a document once every passage has been embedded.
#
# Separate from embedding so a summary that fails does not undo the embeddings,
# which are the expensive part and the thing everything else depends on.
class SummarizeDocumentJob < ApplicationJob
  queue_as :default

  retry_on ProcessingError::ServiceUnavailable,
           wait: EmbedChunkBatchJob::RETRY_WAIT, attempts: 3 do |job, error|
    document = Document.find_by(id: job.arguments.first)
    Rails.logger.error("[summary] document=#{job.arguments.first} giving up: #{error.message}")
    # The passages are embedded and searchable, so the document is still usable
    # for questions even without a summary. Marking it ready with no summary is
    # a better outcome than marking it failed.
    document&.update(status: "ready")
  end

  def perform(document_id)
    document = Document.live.find_by(id: document_id)
    return if document.nil? || !document.summarizing?

    summary = DocumentSummarizer.new(document).call

    document.update!(
      status: "ready",
      summary: summary.bullets.join("\n"),
      title: summary.title.presence || document.title
    )
    Rails.logger.info("[summary] document=#{document.id} summarised in #{summary.bullets.length} points")
  rescue ProcessingError::Unreadable
    # Nothing retrievable to summarise from; the document is still searchable.
    document&.update(status: "ready")
  end
end
