require "test_helper"

class RetentionTest < ActionDispatch::IntegrationTest
  # The period itself, pinned. Every other assertion here derives from the
  # constant, so without this one a change to it would quietly rewrite the
  # promise and still pass.
  test "documents are kept for thirty minutes" do
    assert_equal 30.minutes, Document::RETENTION
  end

  # D3: the promise is stated, not implied. This app writes files to disk, which
  # its predecessor never did.
  test "the upload page says how long a document is kept" do
    get root_path

    assert_select "p", /#{Document::RETENTION.inspect} after you add it/i
  end

  test "the document page names the time it will be removed" do
    document = Document.create!(status: "ready", title: "doc.pdf")

    get document_path(document)

    assert_select "p", /#{Document::RETENTION.inspect} after you added it/i
    assert_select "strong", text: document.expires_at.strftime("%-l:%M %p")
  end

  test "uploading schedules the removal for one retention window later" do
    assert_enqueued_with(job: DeleteDocumentJob) do
      post documents_path, params: {
        document: Rack::Test::UploadedFile.new(HostilePdfs.benign_document_pdf, "application/pdf")
      }
    end

    document = Document.last
    assert_in_delta Document::RETENTION.from_now.to_i, document.expires_at.to_i, 5
  end

  # The column is what makes the promise true; the job only frees the bytes.
  test "an expired document is unreachable even when nothing has deleted it" do
    document = Document.create!(status: "ready", title: "doc.pdf", expires_at: 1.minute.ago)

    get document_path(document)

    assert_redirected_to root_path
    assert Document.exists?(document.id), "this test is meaningless if the row was deleted"
  end

  test "an expired document cannot be asked about either" do
    document = Document.create!(status: "ready", title: "doc.pdf", expires_at: 1.minute.ago)

    stub_gemini do |fake|
      post document_messages_path(document), params: { question: "Anything?" }

      assert_equal 0, fake.call_count
    end

    assert_redirected_to root_path
  end
end
