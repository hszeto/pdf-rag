class DocumentsController < ApplicationController
  before_action :load_document, only: :show

  # Uploading is the expensive request: it embeds every chunk of a document, and
  # on a 512 MB box it parses the whole file in the web process before that.
  # Five an hour is more than a reader needs and less than a script wants.
  #
  # Only :create — reading is free, and the processing screen polls #show every
  # few seconds while a document is read.
  rate_limit to: 5, within: 1.hour, only: :create,
             by: -> { RateLimitKey.for(request.remote_ip) },
             store: FailClosedStore.new,
             with: -> { raise ProcessingError::TooManyDocuments }

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
    scan = PdfSafetyScanner.new(file).scan!

    refuse(scan) unless scan.safe?

    document = store(file, scan)
    IngestDocumentJob.perform_later(document.id)
    DeleteDocumentJob.set(wait_until: document.expires_at).perform_later(document.id)

    redirect_to document_path(document)
  ensure
    discard_tempfile(params[:document])
  end

  def show
  end

  private
    def load_document
      # Scoped to live documents, so one past its window is gone as far as the app
      # is concerned whether or not the sweep has caught up.
      @document = Document.live.find_by(token: params[:id])
      redirect_to root_path, alert: expired_message if @document.nil?
    end

    def expired_message
      "That document has been removed. Documents are kept for #{Document::RETENTION.inspect}."
    end

    def store(file, scan)
      Document.create!(
        status: "pending", title: file.original_filename,
        links: scan.links, attachments: scan.attachments
      ).tap do |document|
        document.file.attach(
          io: File.open(file.tempfile.path), filename: file.original_filename,
          content_type: "application/pdf"
        )
      end
    end

    def refuse(scan)
      Rails.logger.warn("[safety] refused upload: #{scan.blocking.map(&:signal).uniq.join(', ')}")
      raise ProcessingError::Unsafe, scan.blocking.first.signal
    end

    # The uploaded temporary file never outlives the request, on either path.
    def discard_tempfile(file)
      file.tempfile.close! if file.respond_to?(:tempfile) && file.tempfile
    rescue IOError, Errno::ENOENT
      nil
    end
end
