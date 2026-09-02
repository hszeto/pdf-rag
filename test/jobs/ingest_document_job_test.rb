require "test_helper"

class IngestDocumentJobTest < ActiveSupport::TestCase
  test "splits a document into chunks and hands off for embedding" do
    document = stored_document

    IngestDocumentJob.perform_now(document.id)

    document.reload
    assert_equal "embedding", document.status
    assert_operator document.chunks.count, :>, 0
    assert document.content_hash.present?
  end

  # Embedding is a later, per-batch job. This one only prepares the rows, so a
  # failure part-way costs one batch rather than the whole document.
  test "creates chunks without embeddings and makes no external call" do
    document = stored_document

    stub_gemini do |fake|
      IngestDocumentJob.perform_now(document.id)

      assert_equal 0, fake.call_count
    end

    assert_equal document.reload.chunks.count, document.chunks_awaiting_embedding.count
  end

  test "chunks carry their position and page" do
    document = stored_document

    IngestDocumentJob.perform_now(document.id)

    chunks = document.reload.chunks.ordered
    assert_equal (0...chunks.length).to_a, chunks.map(&:position)
    assert chunks.all? { |c| c.page.present? }, "every chunk should know its page"
  end

  # AC 12 / D6
  test "an identical document reuses the existing chunks and embeds nothing" do
    original = ingested_document
    original.chunks.update_all(embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS, 0.05))
    original.update!(status: "ready", summary: "The original summary.")

    duplicate = stored_document

    stub_gemini do |fake|
      IngestDocumentJob.perform_now(duplicate.id)

      assert_equal 0, fake.call_count, "a duplicate must not cost a single embedding call"
    end

    duplicate.reload
    assert_equal "ready", duplicate.status
    assert_equal original.chunks.count, duplicate.chunks.count
    assert_equal "The original summary.", duplicate.summary
    assert duplicate.chunks.all? { |c| c.embedding.present? }
  end

  test "copied chunks belong to the new document, not the original" do
    original = ingested_document
    original.chunks.update_all(embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS, 0.05))
    original.update!(status: "ready")
    duplicate = stored_document
    IngestDocumentJob.perform_now(duplicate.id)

    # Deleting one must not strand the other's passages.
    original.destroy!

    assert_operator duplicate.reload.chunks.count, :>, 0
  end

  test "a document that is not ready is not treated as a twin" do
    half_done = ingested_document
    half_done.update!(status: "embedding")
    duplicate = stored_document

    IngestDocumentJob.perform_now(duplicate.id)

    assert_equal "embedding", duplicate.reload.status
    assert_equal duplicate.chunks.count, duplicate.chunks_awaiting_embedding.count
  end

  # R3.7
  test "an unreadable document is recorded as failed, not left pending" do
    document = stored_document(HostilePdfs.plain_pdf)

    IngestDocumentJob.perform_now(document.id)

    document.reload
    assert_equal "failed", document.status
    assert document.failure_reason.present?
  end

  test "a job whose document expired first does nothing" do
    document = stored_document
    document.update!(expires_at: 1.minute.ago)

    assert_nothing_raised { IngestDocumentJob.perform_now(document.id) }
    assert_equal 0, document.reload.chunks.count
  end

  test "a job for a deleted document does nothing" do
    assert_nothing_raised { IngestDocumentJob.perform_now(-1) }
  end

  test "a document already past pending is left alone" do
    document = stored_document
    document.update!(status: "ready")

    IngestDocumentJob.perform_now(document.id)

    assert_equal 0, document.reload.chunks.count
  end

  private
    def stored_document(path = nil)
      path ||= readable_pdf
      Document.create!(status: "pending", title: File.basename(path)).tap do |document|
        document.file.attach(io: File.open(path), filename: File.basename(path),
                             content_type: "application/pdf")
      end
    end

    def ingested_document
      stored_document.tap { |d| IngestDocumentJob.perform_now(d.id) }
    end

    # A committed fixture rather than one generated at test time: cupsfilter is
    # macOS-only and CI runs on ubuntu, so shelling out to it made these tests
    # pass locally and fail everywhere else.
    def readable_pdf = file_fixture("insurance_sample.pdf").to_s
end
