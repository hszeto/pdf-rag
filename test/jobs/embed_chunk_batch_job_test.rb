require "test_helper"

class EmbedChunkBatchJobTest < ActiveSupport::TestCase
  setup { @document = document_with_chunks(5) }

  # AC 10
  test "every chunk in the batch ends up with a vector of the right size" do
    perform(@document.chunks.pluck(:id), vectors: 5)

    @document.reload.chunks.each do |chunk|
      assert chunk.embedding.present?, "chunk #{chunk.position} was left unembedded"
      assert_equal GeminiClient::EMBEDDING_DIMENSIONS, chunk.embedding.length
    end
  end

  test "the document becomes ready once nothing is left to embed" do
    perform(@document.chunks.pluck(:id), vectors: 5)

    assert_equal "ready", @document.reload.status
  end

  # The database is the coordinator: whichever batch finds nothing left is the
  # last one. No counters, no locks.
  test "a document is not ready while another batch is outstanding" do
    first_half = @document.chunks.ordered.limit(2).pluck(:id)

    perform(first_half, vectors: 2)

    assert_equal "embedding", @document.reload.status
    assert_equal 3, @document.chunks_awaiting_embedding.count
  end

  test "the last batch to finish is the one that marks it ready" do
    ordered = @document.chunks.ordered.pluck(:id)

    perform(ordered.first(2), vectors: 2)
    assert_equal "embedding", @document.reload.status

    perform(ordered.drop(2), vectors: 3)
    assert_equal "ready", @document.reload.status
  end

  # Vectors come back positionally, so the wrong order would attach one
  # passage's meaning to another.
  test "vectors are matched to the chunks they were built from" do
    chunks = @document.chunks.ordered.to_a
    distinct = chunks.each_index.map { |i| Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { i.to_f } }
    response = { "embeddings" => distinct.map { |v| { "values" => v } } }

    stub_gemini(response) do
      EmbedChunkBatchJob.perform_now(@document.id, chunks.map(&:id))
    end

    @document.reload.chunks.ordered.each_with_index do |chunk, i|
      assert_equal i.to_f, chunk.embedding.first,
        "chunk at position #{i} got another chunk's vector"
    end
  end

  # AC 11. A rate limit is the expected case on the free tier, so it must not be
  # the end of the document — the batch retries, and only a persistent failure
  # gives up.
  test "a rate limit schedules a retry rather than failing the document" do
    assert_enqueued_with(job: EmbedChunkBatchJob) do
      stub_gemini([ 429, "quota exhausted" ]) do
        EmbedChunkBatchJob.perform_now(@document.id, @document.chunks.pluck(:id))
      end
    end

    assert_equal "embedding", @document.reload.status, "one 429 must not end the document"
    assert_nil @document.failure_reason
  end

  test "a document is recorded as failed only once retries are exhausted" do
    perform_enqueued_jobs do
      stub_gemini(*Array.new(8) { [ 429, "quota exhausted" ] }) do
        EmbedChunkBatchJob.perform_later(@document.id, @document.chunks.pluck(:id))
      end
    end

    @document.reload
    assert_equal "failed", @document.status
    assert_match(/trouble reading documents/i, @document.failure_reason)
  end

  test "a retry embeds the chunks that the failed attempt did not" do
    ids = @document.chunks.pluck(:id)

    stub_gemini([ 503, "down" ]) do
      EmbedChunkBatchJob.perform_now(@document.id, ids)
    rescue ProcessingError::ServiceUnavailable
      nil
    end
    assert_equal 5, @document.reload.chunks_awaiting_embedding.count

    perform(ids, vectors: 5)

    assert_equal 0, @document.reload.chunks_awaiting_embedding.count
    assert_equal "ready", @document.reload.status
  end

  test "chunks already embedded are not embedded again" do
    @document.chunks.ordered.first(3).each do |chunk|
      chunk.update_column(:embedding, Array.new(GeminiClient::EMBEDDING_DIMENSIONS, 0.5))
    end

    stub_gemini(gemini_embeddings(2)) do |fake|
      EmbedChunkBatchJob.perform_now(@document.id, @document.chunks.pluck(:id))

      assert_equal 2, fake.calls.first[:body]["requests"].length,
        "only the two unembedded chunks should have been sent"
    end
  end

  test "a batch for an expired document does nothing" do
    @document.update!(expires_at: 1.minute.ago)

    stub_gemini do |fake|
      EmbedChunkBatchJob.perform_now(@document.id, @document.chunks.pluck(:id))

      assert_equal 0, fake.call_count
    end
  end

  test "a batch for a deleted document does nothing" do
    stub_gemini do |fake|
      assert_nothing_raised { EmbedChunkBatchJob.perform_now(-1, [ 1, 2 ]) }
      assert_equal 0, fake.call_count
    end
  end

  test "a batch for a document that already failed does nothing" do
    @document.update!(status: "failed")

    stub_gemini do |fake|
      EmbedChunkBatchJob.perform_now(@document.id, @document.chunks.pluck(:id))

      assert_equal 0, fake.call_count
    end
  end

  # A duplicate delivery must not re-embed or double-mark.
  test "running the same batch twice is harmless" do
    ids = @document.chunks.pluck(:id)
    perform(ids, vectors: 5)

    stub_gemini do |fake|
      EmbedChunkBatchJob.perform_now(@document.id, ids)

      assert_equal 0, fake.call_count, "nothing left to embed, so nothing should be sent"
    end

    assert_equal "ready", @document.reload.status
  end


  # Retrying must fit inside the hour a document is kept. Rails' polynomial
  # backoff spaced six attempts across 38 minutes — most of that hour — to wait
  # out a budget that resets every sixty seconds.
  test "the retry schedule fits comfortably inside a document's life" do
    total = EmbedChunkBatchJob::RETRY_WAIT * 5

    assert_operator total, :<, Document::RETENTION / 4,
      "retries should not consume a meaningful share of the document's hour"
  end

  test "the wait is at least one rate-limit window" do
    assert_operator EmbedChunkBatchJob::RETRY_WAIT, :>=, 60.seconds,
      "waiting less than a minute cannot clear a per-minute budget"
  end
  private
    def document_with_chunks(count)
      Document.create!(status: "embedding", title: "doc.pdf").tap do |document|
        count.times do |i|
          document.chunks.create!(content: "passage number #{i}", position: i, page: i + 1)
        end
      end
    end

    def perform(ids, vectors:)
      stub_gemini(gemini_embeddings(vectors)) do
        EmbedChunkBatchJob.perform_now(@document.id, ids)
      end
    end
end
