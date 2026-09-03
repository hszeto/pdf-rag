require "test_helper"

# R1.1 and R1.2: how a document was cut up is ours to know. The reader is told
# about pages, which belong to their document, and never about passages.
class ProgressReportingTest < ActionDispatch::IntegrationTest
  test "the ready screen never mentions passages" do
    document = ready_document

    get document_path(document)

    assert_response :success
    assert_no_match(/passage/i, response.body)
  end

  test "the processing screen never mentions passages" do
    document = document_of(7, embedded: 2)

    get document_path(document)

    assert_response :success
    assert_no_match(/passage/i, response.body)
  end

  test "the processing screen reports the page it has reached" do
    document = document_of(12, embedded: 5)

    get document_path(document)

    assert_select "p", /Reading page 5 of 12/
  end

  # Between the chunk rows being written and the first batch returning there is
  # a total but no progress, and half a fact is worse than none.
  test "no page numbers appear before anything is embedded" do
    document = document_of(5, embedded: 0)

    get document_path(document)

    assert_select "p", text: /Reading page/, count: 0
  end

  test "no page numbers appear while the document is still being extracted" do
    document = Document.create!(status: "extracting", title: "doc.pdf")

    get document_path(document)

    assert_select "p", text: /Reading page/, count: 0
  end

  # The spinner and the rotating message carry the wait on their own when there
  # is nothing truthful to count.
  test "the processing screen still says what it is doing without page numbers" do
    document = Document.create!(status: "extracting", title: "doc.pdf")

    get document_path(document)

    assert_select "h2", text: /Reading your document/
  end

  private
    def vector = Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { 0.01 }

    def ready_document
      Document.create!(
        status: "ready", title: "doc.pdf",
        summary: "It explains what the plan covers.\nIt lists what you pay."
      ).tap { |document| document.chunks.create!(content: "text", position: 0, page: 1, embedding: vector) }
    end

    def document_of(pages, embedded:)
      Document.create!(status: "embedding", title: "doc.pdf").tap do |document|
        (1..pages).each do |page|
          document.chunks.create!(
            content: "text from page #{page}", position: page - 1, page: page,
            embedding: page <= embedded ? vector : nil
          )
        end
      end
    end
end
