class DocumentsController < ApplicationController
  def new
  end

  # Validation and safety screening both happen here, on the request, before
  # anything is stored. A job would have to store the file first, which is
  # exactly what R1.5 forbids: a refused document is never written anywhere.
  #
  # The cost is real — roughly 2 seconds on a 140-page document, almost all of it
  # parsing — and it is the price of that guarantee.
  def create
    file = params[:document]
    DocumentValidator.new(file).validate!
    @scan = PdfSafetyScanner.new(file).scan!

    refuse(@scan) unless @scan.safe?

    # Storing and ingesting the accepted document arrives with the Document
    # model in the next checkpoint.
    render :accepted
  ensure
    discard_tempfile(params[:document])
  end

  private
    def refuse(scan)
      signal = scan.blocking.first.signal
      Rails.logger.warn("[safety] refused upload: #{scan.blocking.map(&:signal).uniq.join(', ')}")
      raise ProcessingError::Unsafe, signal
    end

    # The bytes never outlive the request, on either path.
    def discard_tempfile(file)
      file.tempfile.close! if file.respond_to?(:tempfile) && file.tempfile
    rescue IOError, Errno::ENOENT
      nil
    end
end
