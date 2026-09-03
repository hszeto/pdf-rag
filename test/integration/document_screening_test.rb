require "test_helper"

class DocumentScreeningTest < ActionDispatch::IntegrationTest
  # AC 1
  test "a document with a script that runs on open is refused, and says why" do
    post_pdf HostilePdfs.javascript_pdf

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /script that runs when the file is opened/i
    assert_select "input[type=file]", 1, "a refusal always comes with a way to try again"
  end

  # AC 2
  test "a document that runs another program is refused" do
    post_pdf HostilePdfs.launch_pdf

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /run another program/i
  end

  # AC 3
  test "a document with an attached program is refused" do
    post_pdf HostilePdfs.executable_attachment_pdf

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /attached program/i
  end

  # AC 4, by proxy
  test "an ordinary document with an attachment and links is accepted and stored" do
    assert_difference -> { Document.count }, 1 do
      post_pdf HostilePdfs.benign_document_pdf
    end

    assert_redirected_to document_path(Document.last)
    assert Document.last.file.attached?
  end

  # D1: never hidden, never blocking.
  test "the links found are shown to the reader" do
    post_pdf HostilePdfs.benign_document_pdf
    follow_redirect!

    assert_select "section", /What's inside this document/i
    assert_select "li", text: "http://www.dfs.ny.gov/"
    assert_select "li", text: "mailto:UHC_Civil_Rights@uhc.com"
  end

  # Links come from an untrusted file; showing them as anchors would invite the
  # click the reader is being asked to judge.
  test "links are shown as text, never as clickable anchors" do
    post_pdf HostilePdfs.benign_document_pdf
    follow_redirect!

    assert_select "a[href^=?]", "http://www.dfs.ny.gov", 0
    assert_select "a[href^=?]", "mailto:", 0
  end

  test "an attachment is named rather than blocked" do
    post_pdf HostilePdfs.benign_document_pdf
    follow_redirect!

    assert_select "section", /Content Credentials/
  end

  # AC 6
  test "a file the scanner cannot parse is refused" do
    post_pdf HostilePdfs.truncated_pdf

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /damaged/i
  end

  test "a file that is not a PDF never reaches the scanner" do
    post_pdf HostilePdfs.not_a_pdf

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /only read PDF files/i
  end

  test "posting no file at all is handled" do
    post documents_path

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /did not get a file/i
  end

  # AC 5, in the part that is verifiable before storage exists.
  # AC 5, now fully checkable: nothing sent, and nothing stored.
  test "a refused document is never stored and never sent anywhere" do
    stub_gemini do |fake|
      assert_no_difference -> { Document.count } do
        post_pdf HostilePdfs.javascript_pdf
      end

      assert_equal 0, fake.call_count
      assert_equal 0, ActiveStorage::Blob.count
    end
  end

  test "no uploaded file is left behind, on either path" do
    [ HostilePdfs.benign_document_pdf, HostilePdfs.javascript_pdf ].each do |path|
      before = multipart_tempfiles

      post_pdf path

      assert_empty multipart_tempfiles - before, "#{File.basename(path)} left a temporary file behind"
    end
  end


  # The link between accepting a document and actually reading it was untested:
  # the controller could have stopped enqueuing and every other test stayed green.
  test "an accepted document is queued for ingestion" do
    assert_enqueued_with(job: IngestDocumentJob) do
      post_pdf HostilePdfs.benign_document_pdf
    end
  end

  test "a refused document is never queued for ingestion" do
    assert_no_enqueued_jobs only: IngestDocumentJob do
      post_pdf HostilePdfs.javascript_pdf
    end
  end

  test "the document page reports progress while it is being read" do
    post_pdf HostilePdfs.benign_document_pdf
    follow_redirect!

    assert_response :success
    assert_select "h1"
  end

  # Retention is a property of the data, so a document past its window is gone as
  # far as the app is concerned whether or not anything has deleted it.
  test "an expired document is not reachable" do
    post_pdf HostilePdfs.benign_document_pdf
    document = Document.last
    document.update!(expires_at: 1.minute.ago)

    get document_path(document)

    assert_redirected_to root_path
    assert_match(/removed/i, flash[:alert])
  end

  test "an unknown document id does not blow up" do
    get document_path(id: 999_999)

    assert_redirected_to root_path
  end
  private
    def post_pdf(path)
      post documents_path, params: {
        document: Rack::Test::UploadedFile.new(path, "application/pdf")
      }
    end

    # Scoped to this process; the temp directory is shared with parallel workers.
    def multipart_tempfiles
      Dir.glob(File.join(Dir.tmpdir, "RackMultipart*-#{Process.pid}-*"))
    end
end
