require "test_helper"

class TextChunkerTest < ActiveSupport::TestCase
  # AC 9. Overlap is the reason chunking is not just "split every 500 words":
  # a sentence halved at a boundary ranks for nothing.
  test "a sentence spanning a boundary survives whole in a neighbour" do
    sentence = "the annual deductible is fifteen hundred dollars per year"
    words = ([ "filler" ] * 95) + sentence.split + ([ "filler" ] * 200)
    chunks = chunk(words.join(" "), words_per_chunk: 100, overlap: 30)

    intact = chunks.count { |c| c.content.include?(sentence) }
    assert_operator intact, :>=, 1,
      "the sentence was severed by every boundary it crossed"
  end

  test "consecutive chunks share their overlap" do
    words = (1..300).map { |i| "word#{i}" }
    chunks = chunk(words.join(" "), words_per_chunk: 100, overlap: 20)

    first_tail = chunks[0].content.split.last(20)
    second_head = chunks[1].content.split.first(20)
    assert_equal first_tail, second_head
  end

  test "a document shorter than one chunk yields exactly one" do
    chunks = chunk("just a few words here")

    assert_equal 1, chunks.length
    assert_equal "just a few words here", chunks.first.content
  end

  test "empty input yields no chunks" do
    assert_empty TextChunker.new([]).chunks
    assert_empty chunk("   ")
  end

  test "positions are sequential from zero" do
    chunks = chunk((1..1200).map { |i| "w#{i}" }.join(" "))

    assert_equal (0...chunks.length).to_a, chunks.map(&:position)
  end

  # R3.4: an answer has to be able to say where it came from.
  test "each chunk records the page it began on" do
    pages = [
      page(1, (1..400).map { |i| "a#{i}" }.join(" ")),
      page(2, (1..400).map { |i| "b#{i}" }.join(" ")),
      page(3, (1..400).map { |i| "c#{i}" }.join(" "))
    ]
    chunks = TextChunker.new(pages).chunks

    assert_equal 1, chunks.first.page
    assert_operator chunks.last.page, :>, 1
    assert chunks.map(&:page).each_cons(2).all? { |a, b| b >= a }, "pages should not go backwards"
  end

  # Passages routinely cross page boundaries; splitting there would sever
  # exactly what overlap exists to protect.
  test "chunks are allowed to span pages" do
    pages = [ page(1, (1..300).map { |i| "a#{i}" }.join(" ")),
              page(2, (1..300).map { |i| "b#{i}" }.join(" ")) ]

    spanning = TextChunker.new(pages).chunks.find { |c| c.content.include?("a300") && c.content.include?("b1") }

    assert_not_nil spanning, "no chunk carried the join between two pages"
  end

  # A final window shorter than the overlap is entirely contained in the one
  # before it, so storing it would duplicate a passage for no retrieval benefit.
  test "a final window with nothing new in it is dropped" do
    # 460 words, 500-word window, 50 overlap: the second window is 10 words,
    # all of which the first already holds.
    chunks = chunk((1..460).map { |i| "w#{i}" }.join(" "), words_per_chunk: 500, overlap: 50)

    assert_equal 1, chunks.length
  end

  test "a final window carrying new words is kept" do
    # 510 words leaves a tail holding w501..w510, which nothing else covers.
    chunks = chunk((1..510).map { |i| "w#{i}" }.join(" "), words_per_chunk: 500, overlap: 50)

    assert_equal 2, chunks.length
    assert_includes chunks.last.content.split, "w510"
    assert_not_includes chunks.first.content.split, "w510",
      "the tail must exist because the first chunk does not reach it"
  end

  private
    def page(number, text) = PdfExtractionService::Page.new(number: number, text: text)

    def chunk(text, **options)
      TextChunker.new([ page(1, text) ], **options).chunks
    end
end
