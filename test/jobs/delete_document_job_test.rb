require "test_helper"

class DeleteDocumentJobTest < ActiveSupport::TestCase
  # AC 22
  test "an expired document, its passages and its file are all gone" do
    document = attached_document
    key = document.file.blob.key
    path = ActiveStorage::Blob.service.path_for(key)
    document.chunks.create!(content: "a passage", position: 0)
    document.messages.create!(role: "user", content: "a question")
    document.update!(expires_at: 1.minute.ago)

    DeleteDocumentJob.perform_now(document.id)

    assert Document.where(id: document.id).none?
    assert DocumentChunk.where(document_id: document.id).none?
    assert Message.where(document_id: document.id).none?
    assert ActiveStorage::Blob.where(key: key).none?, "the blob row survived"
    assert_not File.exist?(path), "the uploaded file is still on disk"
  end

  # The file must be gone when the job finishes, not when some later job gets
  # round to it. Active Storage's default defers this.
  test "the file is purged without depending on another queued job" do
    document = attached_document
    path = ActiveStorage::Blob.service.path_for(document.file.blob.key)
    document.update!(expires_at: 1.minute.ago)

    assert_no_enqueued_jobs only: ActiveStorage::PurgeJob do
      DeleteDocumentJob.perform_now(document.id)
    end

    assert_not File.exist?(path)
  end

  # A scheduled job can arrive early after a restart or a clock change.
  test "a document with time left is kept and rescheduled" do
    document = attached_document
    document.update!(expires_at: 30.minutes.from_now)

    assert_enqueued_with(job: DeleteDocumentJob, args: [ document.id ]) do
      DeleteDocumentJob.perform_now(document.id)
    end

    assert Document.exists?(document.id), "a document that still has time was deleted"
  end

  test "a job for an already deleted document does nothing" do
    assert_nothing_raised { DeleteDocumentJob.perform_now(-1) }
  end

  test "a document with no file attached is still removed" do
    document = Document.create!(status: "failed", expires_at: 1.minute.ago)

    assert_nothing_raised { DeleteDocumentJob.perform_now(document.id) }
    assert Document.where(id: document.id).none?
  end

  private
    def attached_document
      Document.create!(status: "ready", title: "doc.pdf").tap do |document|
        document.file.attach(
          io: File.open(file_fixture("insurance_sample.pdf")),
          filename: "doc.pdf", content_type: "application/pdf"
        )
      end
    end
end
