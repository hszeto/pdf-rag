# Gatekeeper for anything arriving from a file field.
#
# Checks run cheapest-first so an oversized or bogus file is rejected before we
# spend anything on it: presence, then size (from the tempfile's stat, without
# reading it), then the magic header (five bytes).
class DocumentValidator
  MAX_BYTES = 15.megabytes
  PDF_MAGIC = "%PDF-".b.freeze

  def initialize(file)
    @file = file
  end

  def validate!
    raise ProcessingError::Missing if @file.blank?
    raise ProcessingError::TooLarge if too_large?
    raise ProcessingError::NotAPdf unless pdf?

    @file
  end

  private
    # Reads the size from the tempfile's stat rather than the content, so a huge
    # file is rejected without ever being pulled into memory (AC 8).
    #
    # Note this is the last line of defence, not the first: Rack has already
    # buffered the request body to disk by the time we get here. Rejecting before
    # that requires a limit at the proxy/web-server layer too (D9).
    def too_large? = @file.size > MAX_BYTES

    # The extension and the browser-supplied content type are both trivially
    # forged, so the header is what actually decides (R3.2).
    def pdf?
      head = read_head
      head.present? && head.start_with?(PDF_MAGIC)
    end

    def read_head
      io = @file.tempfile
      io.rewind
      io.read(PDF_MAGIC.bytesize).to_s.b
    ensure
      io&.rewind
    end
end
