# Reads the document the session is holding and writes back what it found.
#
# Only the session id crosses the queue. The text is already in the cache, so no
# file bytes travel as job arguments and nothing touches disk (R3.5).
class AnalyzeDocumentJob < ApplicationJob
  queue_as :default

  def perform(session_id)
    session = SessionCache.find(session_id)
    # Expired, or explicitly removed, while the job sat in the queue. There is
    # nothing left to read and nobody waiting for it.
    return if session.nil? || !session.analyzing?

    analysis = GeminiClient.new.analyze_document(session.full_text)

    if analysis.insurance?
      store(session, analysis)
    else
      discard(session, ProcessingError::NotInsurance.new)
    end
  rescue ProcessingError => e
    # Recorded on the session rather than re-raised. Sidekiq would keep retrying
    # long after the five minute session had expired, and the reader is sitting
    # in front of a spinner that needs to stop.
    #
    # Because it is not re-raised, Sidekiq counts the job as successful and logs
    # nothing about it — so the reason has to be written down here or it is lost.
    # The session id is safe to log; the document text is not (R9.3).
    Rails.logger.error(
      "[analyze] session=#{session_id} failed #{e.class.name.demodulize}: #{e.message}"
    )
    discard(SessionCache.find(session_id), e)
  end

  private
    def store(session, analysis)
      session.document_type = analysis.document_type
      session.structured_fields = analysis.structured_fields
      session.plain_summary = analysis.plain_summary
      session.status = "extracted"
      SessionCache.write(session)
    end

    # A document we cannot use is thrown away rather than left in the cache for
    # the next five minutes (R5.2).
    def discard(session, error)
      return if session.nil?

      session.full_text = nil
      session.plain_summary = nil
      session.status = "error"
      session.error_message = error.user_message
      SessionCache.write(session)
    end
end
