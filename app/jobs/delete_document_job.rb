# Removes a document once its window is up.
#
# The deletion is not what makes the promise true — `Document.live` already
# hides anything past its expiry, so a job that never runs cannot expose a
# document. What this job does is free the bytes: the row, its passages, and the
# uploaded file on disk.
class DeleteDocumentJob < ApplicationJob
  queue_as :default

  def perform(document_id)
    document = Document.find_by(id: document_id)
    return if document.nil?

    # Scheduled jobs can arrive early after a restart or a clock change. A
    # document that still has time left keeps it.
    return reschedule(document) if document.expires_at.future?

    document.remove!
    Rails.logger.info("[retention] document=#{document_id} removed")
  end

  private
    def reschedule(document)
      DeleteDocumentJob.set(wait_until: document.expires_at).perform_later(document.id)
    end
end
