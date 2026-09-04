require "test_helper"

# The app has no accounts and a card attached to the model provider, so the only
# thing between a stranger and an unbounded bill is a per-visitor ceiling.
#
# Each test uses its own client address: the cache is a MemoryStore per parallel
# worker, so counters would otherwise leak between tests in the same process.
class RateLimitingTest < ActionDispatch::IntegrationTest
  setup { @document = searchable_document }

  test "a sixth upload within the hour is refused" do
    5.times { |i| upload from: "203.0.113.1" }

    upload from: "203.0.113.1"

    assert_response :too_many_requests
    assert_select "[role=alert]", /a lot of documents in a short time/i
  end

  test "the sixth upload from a different visitor is not refused" do
    5.times { upload from: "203.0.113.2" }

    upload from: "203.0.113.3"

    assert_response :redirect, "a second visitor has their own allowance"
  end

  # Both arrive through the same Cloudflare edge; only the leftmost hop differs.
  test "two visitors behind one edge are counted apart" do
    5.times { upload from: "203.0.113.4" }

    upload from: "203.0.113.5"

    assert_response :redirect
  end

  test "a twenty-first question within the minute is refused" do
    20.times { ask from: "203.0.113.6" }

    ask from: "203.0.113.6"

    assert_response :too_many_requests
    assert_select "[role=alert]", /a lot of questions in a short time/i
  end

  # AC2: the browser asks for a stream, and a refusal has to arrive as something
  # Turbo can render rather than a bare status.
  test "a refused question answers a turbo stream request with a page" do
    20.times { ask from: "203.0.113.7" }

    ask from: "203.0.113.7", as: :turbo_stream

    assert_response :too_many_requests
    assert_equal "text/html", response.media_type
    assert_select "[role=alert]", /a lot of questions/i
  end

  # AC11: the processing screen polls #show every few seconds while a document is
  # read. Limiting reads would break the wait, and reading costs nothing.
  test "reading a document is never limited" do
    30.times { get document_path(@document), headers: from("203.0.113.8") }

    assert_response :success
  end

  # D9: failing closed. Rails' limiter reads a nil from the store as "no limit",
  # which would switch rate limiting off exactly when the cache is unwell.
  test "an upload is refused when the counter cannot be reached" do
    assert_no_difference "Document.count", "nothing should have been stored" do
      with_broken_cache { upload from: "203.0.113.9" }
    end

    assert_response :service_unavailable
    assert_select "[role=alert]", /cannot take that just now/i
  end

  test "a question is refused when the counter cannot be reached" do
    with_broken_cache { ask from: "203.0.113.10" }

    assert_response :service_unavailable
    assert_equal 0, @document.messages.count
  end

  private
    def from(ip) = { "HTTP_X_FORWARDED_FOR" => ip }

    # Stands in for the cache swallowing an error and returning nil, which is
    # what production.rb's error_handler does.
    def with_broken_cache
      original = Rails.cache
      Rails.cache = Class.new { def increment(*, **) = nil }.new
      yield
    ensure
      Rails.cache = original
    end

    def upload(from:)
      post documents_path,
        params: { document: Rack::Test::UploadedFile.new(HostilePdfs.benign_document_pdf, "application/pdf") },
        headers: from(from)
    end

    def ask(from:, as: nil)
      stub_gemini(gemini_embeddings(1), gemini_answer(text: "Yes.", used: [ 1 ])) do
        post document_messages_path(@document),
          params: { question: "Anything?" }, headers: from(from), as: as
      end
    end

    def searchable_document
      Document.create!(status: "ready", title: "doc.pdf", summary: "A summary.").tap do |document|
        3.times do |i|
          document.chunks.create!(content: "passage #{i} " * 20, position: i, page: i + 1,
                                  embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { rand })
        end
      end
    end
end
