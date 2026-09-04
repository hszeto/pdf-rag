require "test_helper"

# Documents used to be addressed by their sequential primary key, so a reader
# could reach someone else's by counting. These check the id is no longer a way
# in, and that nothing internal moved with the URL.
class DocumentUrlsTest < ActionDispatch::IntegrationTest
  setup { @document = Document.create!(status: "ready", title: "d.pdf", summary: "A summary.") }

  test "the path carries the token, not the primary key" do
    path = document_path(@document)

    assert_includes path, @document.token
    assert_not_includes path, @document.id.to_s
  end

  test "a document is reachable by its token" do
    get document_path(@document)

    assert_response :success
  end

  # The point of the whole change: the id must stop being an address.
  test "a document is not reachable by its primary key" do
    get "/documents/#{@document.id}"

    assert_redirected_to root_path
  end

  test "counting to a neighbour finds nothing" do
    other = Document.create!(status: "ready", title: "other.pdf")

    get "/documents/#{other.id}"

    assert_redirected_to root_path
  end

  test "questions are asked through the token route" do
    @document.chunks.create!(content: "text", position: 0, page: 1,
                             embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { 0.01 })

    stub_gemini(gemini_embeddings(1), gemini_answer(text: "Yes.", used: [ 1 ])) do
      post document_messages_path(@document), params: { question: "Anything?" }
    end

    assert_response :redirect
    assert_equal 2, @document.messages.count
  end

  test "two documents have unrelated tokens" do
    other = Document.create!(status: "ready", title: "other.pdf")

    assert_not_equal @document.token, other.token
    assert_equal 24, @document.token.length
  end

  # D4: the migration backfills, so a row that predates the column is still
  # addressable. update_columns skips the callback, standing in for that state.
  test "a document that predates the token column is reachable once given one" do
    @document.update_columns(token: SecureRandom.base58(24))

    get document_path(@document.reload)

    assert_response :success
  end

  # has_secure_token only generates when the attribute is blank, so setting one
  # explicitly is enough to collide. The database, not the model, must refuse.
  test "the token column refuses a duplicate" do
    other = Document.new(status: "ready", title: "other.pdf", token: @document.token)

    assert_raises(ActiveRecord::RecordNotUnique) { other.save! }
  end
end
