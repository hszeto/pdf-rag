require "test_helper"

# R1.4. `nil` is the signal for "not knowable yet", and the processing screen
# renders nothing until both numbers are real — so the nil cases matter as much
# as the values, and are checked as carefully.
class DocumentTest < ActiveSupport::TestCase
  test "both are nil before any chunk exists" do
    document = Document.create!(status: "extracting", title: "doc.pdf")

    assert_nil document.page_count
    assert_nil document.pages_read
  end

  test "page_count is the last page that produced text" do
    document = document_of(4, embedded: 0)

    assert_equal 4, document.page_count
  end

  test "pages_read is nil until something has been embedded" do
    document = document_of(4, embedded: 0)

    assert_nil document.pages_read
  end

  test "pages_read is the furthest page carrying an embedding" do
    document = document_of(9, embedded: 3)

    assert_equal 3, document.pages_read
    assert_equal 9, document.page_count
  end

  test "pages_read reaches page_count once everything is embedded" do
    document = document_of(6, embedded: 6)

    assert_equal document.page_count, document.pages_read
  end

  # A chunk's page is nullable, and `maximum` over nulls is nil rather than 0 —
  # which is what keeps "Reading page  of " off the screen.
  test "both are nil when chunks carry no page" do
    document = Document.create!(status: "embedding", title: "doc.pdf")
    document.chunks.create!(content: "text", position: 0, page: nil, embedding: vector)

    assert_nil document.page_count
    assert_nil document.pages_read
  end

  private
    def vector = Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { 0.01 }

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
