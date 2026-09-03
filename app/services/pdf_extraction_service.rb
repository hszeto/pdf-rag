# Pulls the words out of a PDF, and turns pdf-reader's failures into errors that
# already know what to say to the user.
#
# The whole document is read. The 20-page cap this carried in its previous life
# existed because everything was sent to the model; retrieval replaces it.
class PdfExtractionService
  # Below this the file is almost certainly a scan or a photo rather than a text
  # document. Reading those is out of scope.
  MINIMUM_TEXT_LENGTH = 200

  Page = Struct.new(:number, :text, keyword_init: true)

  # The reader is injected so its failure modes can be driven in tests. This
  # project has no mocking library, so a seam is the only way to reach the
  # encrypted-PDF branch, which we cannot produce a real fixture for.
  def initialize(file, reader: PDF::Reader)
    @file = file
    @reader = reader
  end

  # Page-by-page, so a chunk can say which page it came from (R3.4).
  def pages
    @pages ||= begin
      texts = read_pages
      raise ProcessingError::Unreadable if texts.sum { |t| t.strip.length } < MINIMUM_TEXT_LENGTH

      texts.each_with_index.map { |text, i| Page.new(number: i + 1, text: text) }
    end
  end

  def extract! = pages.map(&:text).join("\n")

  private
    def read_pages
      @reader.new(source).pages.map(&:text)
    # EncryptedPDFError is a subclass of UnsupportedFeatureError, so it has to be
    # rescued first to keep "locked" distinct from "damaged".
    rescue PDF::Reader::EncryptedPDFError
      raise ProcessingError::Locked
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
      raise ProcessingError::Damaged
    rescue ProcessingError
      raise
    rescue StandardError
      # pdf-reader surfaces a lot of malformed input through generic exceptions
      # rather than its own hierarchy; a broken file must not become a 500.
      raise ProcessingError::Damaged
    end

    def source
      return @file.tempfile if @file.respond_to?(:tempfile)
      return @file.path if @file.respond_to?(:path) && !@file.is_a?(String)

      @file
    end
end
