require "test_helper"

class UsageRecordingTest < ActionDispatch::IntegrationTest
  test "an accepted upload is recorded once, with its real size" do
    path = HostilePdfs.benign_document_pdf

    assert_difference -> { UsageEvent.uploads.count }, 1 do
      post_pdf path
    end

    assert_equal File.size(path), UsageEvent.uploads.sole.byte_size
    assert_equal 0, UsageEvent.refusals.count
  end

  test "a refused upload is recorded as a refusal, and never as an upload" do
    assert_difference -> { UsageEvent.refusals.count }, 1 do
      post_pdf HostilePdfs.javascript_pdf
    end

    assert_response :unprocessable_entity
    assert_equal 0, UsageEvent.uploads.count
    assert_nil UsageEvent.refusals.sole.byte_size
  end

  test "a file that is not a PDF is recorded as a refusal" do
    assert_difference -> { UsageEvent.refusals.count }, 1 do
      post_pdf HostilePdfs.not_a_pdf
    end
  end

  # rate_limit runs as a before_action, so this never enters the action and is
  # recorded at the limiter instead. Without that, the busiest refusals of all
  # would be the only ones missing.
  test "a rate-limited upload is recorded as a refusal" do
    6.times { post_pdf HostilePdfs.plain_pdf }

    assert_response :too_many_requests
    assert_equal 5, UsageEvent.uploads.count
    assert_equal 1, UsageEvent.refusals.count
  end

  # AC3: the row has to outlive the thing it counts, or the whole feature is
  # pointless — every document is gone within thirty minutes.
  test "records survive the document being deleted and swept" do
    post_pdf HostilePdfs.benign_document_pdf
    document = Document.last

    DeleteDocumentJob.perform_now(document.id)
    Document.update_all(expires_at: 1.hour.ago)
    SweepExpiredDocumentsJob.perform_now

    assert_equal 0, Document.count, "the documents should be gone"
    assert_equal 1, UsageEvent.uploads.count, "the record of them should not be"
  end

  test "two visitors behind different addresses count as two" do
    post_pdf HostilePdfs.plain_pdf, headers: { "REMOTE_ADDR" => "203.0.113.1" }
    post_pdf HostilePdfs.plain_pdf, headers: { "REMOTE_ADDR" => "203.0.113.2" }

    assert_equal 2, UsageEvent.summary[:visitors]
  end

  private
    def post_pdf(path, headers: {})
      post documents_path,
        params: { document: fixture_file_upload(path, "application/pdf") },
        headers: headers
    end
end
