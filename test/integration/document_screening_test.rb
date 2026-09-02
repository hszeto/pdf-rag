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
  test "an ordinary document with an attachment and links is accepted" do
    post_pdf HostilePdfs.benign_document_pdf

    assert_response :success
    assert_select "h1", /looks safe/i
  end

  # D1: never hidden, never blocking.
  test "the links found are shown to the reader" do
    post_pdf HostilePdfs.benign_document_pdf

    assert_select "section", /What's inside this document/i
    assert_select "li", text: "http://www.dfs.ny.gov/"
    assert_select "li", text: "mailto:UHC_Civil_Rights@uhc.com"
  end

  # Links come from an untrusted file; showing them as anchors would invite the
  # click the reader is being asked to judge.
  test "links are shown as text, never as clickable anchors" do
    post_pdf HostilePdfs.benign_document_pdf

    assert_select "a[href^=?]", "http://www.dfs.ny.gov", 0
    assert_select "a[href^=?]", "mailto:", 0
  end

  test "an attachment is named rather than blocked" do
    post_pdf HostilePdfs.benign_document_pdf

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
    post document_path

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /did not get a file/i
  end

  # AC 5, in the part that is verifiable before storage exists.
  test "a refused document is never sent anywhere" do
    stub_gemini do |fake|
      post_pdf HostilePdfs.javascript_pdf

      assert_equal 0, fake.call_count
    end
  end

  test "no uploaded file is left behind, on either path" do
    [ HostilePdfs.benign_document_pdf, HostilePdfs.javascript_pdf ].each do |path|
      before = multipart_tempfiles

      post_pdf path

      assert_empty multipart_tempfiles - before, "#{File.basename(path)} left a temporary file behind"
    end
  end

  private
    def post_pdf(path)
      post document_path, params: {
        document: Rack::Test::UploadedFile.new(path, "application/pdf")
      }
    end

    # Scoped to this process; the temp directory is shared with parallel workers.
    def multipart_tempfiles
      Dir.glob(File.join(Dir.tmpdir, "RackMultipart*-#{Process.pid}-*"))
    end
end
