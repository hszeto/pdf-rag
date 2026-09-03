# Splits a document into overlapping passages small enough to embed and specific
# enough to retrieve.
#
# Overlap is the whole point: a sentence that straddles a boundary would
# otherwise be halved, and neither half would rank for a question about it. Every
# chunk repeats the tail of its predecessor, so a straddling sentence survives
# intact in at least one of them.
#
# 500 words is a starting point rather than a validated choice. Retrieval quality
# against real documents is measured once the pipeline works end to end.
class TextChunker
  WORDS_PER_CHUNK = 500
  OVERLAP_WORDS = 50

  Chunk = Struct.new(:content, :position, :page, keyword_init: true)

  def initialize(pages, words_per_chunk: WORDS_PER_CHUNK, overlap: OVERLAP_WORDS)
    @pages = pages
    @words_per_chunk = words_per_chunk
    @overlap = overlap
  end

  def chunks
    words = flatten_pages
    return [] if words.empty?

    stride = @words_per_chunk - @overlap
    windows = (0...words.length).step(stride).map { |start| words[start, @words_per_chunk] }

    # The last window can be a pure subset of the one before it, which would
    # store the same passage twice for no retrieval benefit.
    windows = windows.reject.with_index do |window, i|
      i.positive? && window.length < @overlap
    end

    windows.each_with_index.map do |window, position|
      Chunk.new(
        content: window.map(&:first).join(" "),
        position: position,
        page: window.first.last
      )
    end
  end

  private
    # A flat list of [word, page] so a window can report the page it began on
    # without chunking having to respect page boundaries — passages routinely
    # cross them, and splitting there would sever exactly what overlap protects.
    def flatten_pages
      @pages.flat_map do |page|
        page.text.to_s.split(/\s+/).reject(&:empty?).map { |word| [ word, page.number ] }
      end
    end
end
