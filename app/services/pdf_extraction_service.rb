# Pulls the words out of a PDF, and turns pdf-reader's failures into errors that
# already know what to say to the user.
class PdfExtractionService
  # Below this, the file is almost certainly a scan or a photo rather than a text
  # document. Reading those is deferred (D3).
  MINIMUM_TEXT_LENGTH = 200

  # Real policy documents are far longer than the summaries this was first built
  # for. One measured 140 pages and ~106,000 tokens, and took 15.8 seconds to
  # read; capped at 20 pages the same file takes 2.3 seconds and yields ~13,200
  # tokens. The fields the plan screen shows all appear by page 4, so the cap
  # costs nothing for the documents people actually ask about (D12).
  #
  # The trade-off is that a question answerable only from the later pages cannot
  # be answered. The app says so plainly and offers the plan phone number, which
  # is a better outcome than a slow, expensive, or invented one.
  MAX_PAGES = 20

  # The reader is injected so its failure modes can be driven directly in tests.
  # This project has no mocking library — Minitest 6 dropped Minitest::Mock and
  # there is no webmock or mocha — so a seam like this is the only way to reach
  # the encrypted-PDF branch, which we cannot produce a real fixture for.
  def initialize(file, reader: PDF::Reader)
    @file = file
    @reader = reader
  end

  def extract!
    text = read_text

    raise ProcessingError::Unreadable if text.strip.length < MINIMUM_TEXT_LENGTH

    text
  end

  private
    def read_text
      @reader.new(@file.tempfile).pages.first(MAX_PAGES).map(&:text).join("\n")
    # EncryptedPDFError is a subclass of UnsupportedFeatureError, so it has to be
    # rescued first to keep "locked" distinct from "damaged" (R3.4, R4.4).
    rescue PDF::Reader::EncryptedPDFError
      raise ProcessingError::Locked
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
      raise ProcessingError::Damaged
    rescue StandardError
      # pdf-reader surfaces a lot of malformed input through generic exceptions
      # rather than its own hierarchy; a broken file must not become a 500.
      raise ProcessingError::Damaged
    end
end
