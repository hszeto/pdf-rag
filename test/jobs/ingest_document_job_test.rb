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


  # AC 24: the whole cost model rests on batching. 136 chunks must be a couple of
  # requests, not 136.
  test "chunks are queued for embedding in batches, not one at a time" do
    document = stored_document

    assert_enqueued_jobs 1, only: EmbedChunkBatchJob do
      IngestDocumentJob.perform_now(document.id)
    end
  end

  # Batches are sized by token budget, not by count: the free tier rejects a
  # request on tokens long before the API's own 100-item ceiling.
  test "a long document is split into batches that fit the token budget" do
    document = stored_document(file_fixture("long_policy.pdf").to_s)

    IngestDocumentJob.perform_now(document.id)

    batches = enqueued_jobs.select { |j| j[:job] == EmbedChunkBatchJob }
    chunks = document.reload.chunks.ordered.index_by(&:id)

    assert_operator batches.length, :>=, 1
    batches.each do |batch|
      texts = batch[:args].last.map { |id| chunks[id].content }
      tokens = texts.sum { |t| EmbeddingBatches.estimate(t) }
      assert_operator tokens, :<=, EmbeddingBatches::MAX_TOKENS,
        "a batch was built that the API would reject"
      assert_operator batch[:args].last.length, :<=, EmbeddingBatches::MAX_ITEMS
    end
  end

  test "every chunk is covered by exactly one batch" do
    document = stored_document(file_fixture("long_policy.pdf").to_s)

    IngestDocumentJob.perform_now(document.id)

    queued = enqueued_jobs.select { |j| j[:job] == EmbedChunkBatchJob }.flat_map { |j| j[:args].last }
    assert_equal document.reload.chunks.pluck(:id).sort, queued.sort
  end

  test "a reused document queues no embedding at all" do
    original = ingested_document
    original.chunks.update_all(embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS, 0.05))
    original.update!(status: "ready")

    assert_no_enqueued_jobs only: EmbedChunkBatchJob do
      IngestDocumentJob.perform_now(stored_document.id)
    end
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
