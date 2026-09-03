require "test_helper"

class SummarizeDocumentJobTest < ActiveSupport::TestCase
  setup { @document = embedded_document }

  test "stores the summary and marks the document ready" do
    run_job

    @document.reload
    assert_equal "ready", @document.status
    assert_includes @document.summary, "It is a health plan document."
    assert_includes @document.summary, "It lists what you pay."
  end

  test "adopts the suggested title when there is one" do
    run_job(gemini_summary(title: "Benefits Guide"))

    assert_equal "Benefits Guide", @document.reload.title
  end

  test "keeps the uploaded filename when no title is suggested" do
    run_job(gemini_summary(title: nil))

    assert_equal "doc.pdf", @document.reload.title
  end

  # A summary is a convenience; the embeddings are the substance. Failing to
  # summarise must not cost the reader a searchable document.
  test "a document with no summary is still made ready" do
    perform_enqueued_jobs do
      stub_gemini(*Array.new(9) { [ 429, "quota" ] }) do
        SummarizeDocumentJob.perform_later(@document.id)
      end
    end

    @document.reload
    assert_equal "ready", @document.status, "the passages are searchable even without a summary"
    assert_nil @document.summary
    assert_nil @document.failure_reason, "this is not a failed document"
  end

  test "a document with nothing embedded is made ready rather than failed" do
    @document.chunks.update_all(embedding: nil)

    stub_gemini(gemini_embeddings(1)) do
      SummarizeDocumentJob.perform_now(@document.id)
    end

    assert_equal "ready", @document.reload.status
  end

  test "a transient failure schedules a retry rather than giving up" do
    assert_enqueued_with(job: SummarizeDocumentJob) do
      stub_gemini([ 503, "down" ]) { SummarizeDocumentJob.perform_now(@document.id) }
    end

    assert_equal "summarizing", @document.reload.status
  end

  test "a job for an expired document does nothing" do
    @document.update!(expires_at: 1.minute.ago)

    stub_gemini do |fake|
      SummarizeDocumentJob.perform_now(@document.id)

      assert_equal 0, fake.call_count
    end
  end

  test "a job for a document that is not awaiting a summary does nothing" do
    @document.update!(status: "ready")

    stub_gemini do |fake|
      SummarizeDocumentJob.perform_now(@document.id)

      assert_equal 0, fake.call_count
    end
  end

  test "a job for a deleted document does nothing" do
    assert_nothing_raised { SummarizeDocumentJob.perform_now(-1) }
  end

  private
    def run_job(summary = nil)
      stub_gemini(gemini_embeddings(1), summary || gemini_summary) do
        SummarizeDocumentJob.perform_now(@document.id)
      end
    end

    def embedded_document
      Document.create!(status: "summarizing", title: "doc.pdf").tap do |document|
        6.times do |i|
          document.chunks.create!(
            content: "passage #{i} about coverage and what you pay " * 20,
            position: i, page: i + 1,
            embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { rand }
          )
        end
      end
    end
end
