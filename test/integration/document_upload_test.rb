require "test_helper"

class DocumentUploadTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  test "a valid insurance PDF is read and stored on the session" do
    post document_path, params: { document: upload("insurance_sample.pdf") }

    assert_redirected_to root_path
    session = SessionCache.find(session_id)
    assert_equal "uploaded", session.status
    assert_includes session.full_text, "ACME HEALTH GOLD ADVANTAGE PLAN"
  end

  # AC 7
  test "a JPEG named .pdf is refused with the PDF message and a way to retry" do
    post document_path, params: { document: upload("actually_a_jpeg.pdf") }

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /only read PDF files/i
    assert_select "input[type=file]", 1, "the retry control must be on the same screen"
  end

  # AC 9
  test "a damaged PDF is refused as damaged" do
    post document_path, params: { document: upload("damaged.pdf") }

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /may be damaged/i
    assert_select "input[type=file]", 1
  end

  test "a PDF with no readable words is refused with the scan message" do
    post document_path, params: { document: upload("text_light.pdf") }

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /could not find any words/i
  end

  test "posting no file at all is handled gracefully" do
    post document_path

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /did not get a file/i
  end

  test "nothing is stored on the session when the document is refused" do
    post document_path, params: { document: upload("actually_a_jpeg.pdf") }

    session = SessionCache.find(session_id)
    assert_nil session.full_text
    assert_equal "empty", session.status
  end

  # AC 10: the bytes must not outlive the request, on either path.
  test "no uploaded file remains on disk after success or failure" do
    %w[insurance_sample.pdf actually_a_jpeg.pdf damaged.pdf].each do |fixture|
      before = tempfile_count

      post document_path, params: { document: upload(fixture) }

      assert_equal before, tempfile_count,
        "#{fixture} left a temporary file behind"
    end
  end

# Regression: a visitor who already has a document and is refused a second one
# must still get a file field. Without it the refusal is a dead end, which a
# test starting from a fresh session never notices (R7.5).
test "a refusal still offers a retry when a document is already held" do
  post document_path, params: { document: upload("insurance_sample.pdf") }
  assert_equal "uploaded", SessionCache.find(session_id).status

  post document_path, params: { document: upload("actually_a_jpeg.pdf") }

  assert_response :unprocessable_entity
  assert_select "[role=alert]", /only read PDF files/i
  assert_select "input[type=file]", 1, "a refusal must never leave the visitor without a retry"
end

  test "adding a second document replaces the first" do
    post document_path, params: { document: upload("insurance_sample.pdf") }
    first_length = SessionCache.find(session_id).full_text.length

    post document_path, params: { document: upload("insurance_sample.pdf") }

    assert_equal first_length, SessionCache.find(session_id).full_text.length
    assert_equal 1, cache_session_count, "a second document must not create a second session"
  end

  test "uploading refreshes the idle timer" do
    get root_path
    id = session_id

    travel(4.minutes) do
      post document_path, params: { document: upload("insurance_sample.pdf") }
    end

    travel(8.minutes) do
      assert_not_nil SessionCache.find(id)
    end
  end

  private
    def upload(name) = fixture_file_upload(name, "application/pdf")

    def session_id = session[SessionScoped::SESSION_KEY]

    def cache_session_count
      Rails.cache.instance_variable_get(:@data).keys.count { |k| k.include?(SessionCache::KEY_PREFIX) }
    end

    # Rack buffers multipart bodies into Dir.tmpdir; count what is left behind.
    def tempfile_count = Dir.glob(File.join(Dir.tmpdir, "RackMultipart*")).length
end
