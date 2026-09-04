# Seeds documents to look at without spending a Gemini request.
#
# Nothing in the rendering path calls the language model: embeddings and
# summaries are *written* by the pipeline and only *read* by the views. So a
# document assembled directly here exercises every screen — processing, ready,
# failed, the chat, the retention note — for free.
#
# What still costs a request is going through the front door: uploading a PDF
# runs IngestDocumentJob, and typing a question runs QuestionAnswerer. Seed the
# exchange instead of typing it and the daily cap stays intact.
namespace :demo do
  DIMENSIONS = 3072

  # Stamped on every document this task creates, and the only thing demo:clear
  # will delete. content_hash otherwise holds a SHA256 of the extracted text, so
  # a real upload can never collide with this value.
  SEED_MARKER = "demo-seed".freeze

  desc "Create documents in every screen state, without calling Gemini"
  task seed: :environment do
    abort "demo:seed refuses to run in production" if Rails.env.production?

    docs = {
      "ready, with an exchange" => ready_with_chat,
      "part-way through reading" => mid_embedding,
      "about to expire"          => expiring_soon,
      "failed"                   => failed_document,
      "carrying links"           => with_scan_notes
    }

    puts "\nSeeded #{docs.size} documents:\n\n"
    docs.each do |label, document|
      # to_param, not id: the URL carries the token now.
      puts format("  %-26s http://localhost:3000/documents/%s", label, document.to_param)
    end
    puts "\nRetention is #{Document::RETENTION.inspect}; the 'about to expire' one has " \
         "about a minute left.\n\n"
  end

  desc "Remove the documents demo:seed created, and nothing else"
  task clear: :environment do
    abort "demo:clear refuses to run in production" if Rails.env.production?

    seeded = Document.where(content_hash: SEED_MARKER)
    others = Document.where.not(content_hash: SEED_MARKER).or(Document.where(content_hash: nil))

    count = seeded.count
    seeded.find_each(&:remove!)

    puts "removed #{count} seeded document(s)"
    puts "left #{others.count} document(s) alone — those were not seeded" if others.any?
  end

  # A vector of the right width. The values are irrelevant because nothing here
  # searches — only `embedded` (is it non-null) is ever consulted by the views.
  def self.vector = Array.new(DIMENSIONS) { 0.01 }

  def self.pages(document, count, embedded:)
    rows = (1..count).map do |page|
      {
        document_id: document.id,
        content: "Page #{page}. " + ("Sample body text for this passage. " * 12),
        position: page - 1,
        page: page,
        embedding: page <= embedded ? vector : nil,
        created_at: Time.current, updated_at: Time.current
      }
    end
    DocumentChunk.insert_all!(rows)
    document
  end

  def self.ready_with_chat
    document = Document.create!(
      content_hash: SEED_MARKER,
      status: "ready", title: "Tenancy Agreement.pdf",
      summary: "It is a residential tenancy agreement.\n" \
               "It sets the rent, the deposit and the notice period.\n" \
               "It runs for twelve months from the date of signing."
    )
    pages(document, 24, embedded: 24)

    document.messages.create!(role: "user", content: "How much is the deposit?")
    document.messages.create!(
      role: "assistant",
      content: "The deposit is £1,800, which is six weeks' rent. It is held with a " \
               "government-approved protection scheme within 30 days.",
      citations: [ "page 4" ]
    )
    document.messages.create!(role: "user", content: "How much notice do I have to give?")
    document.messages.create!(
      role: "assistant",
      content: "Two months' written notice, and it cannot end before the twelfth month.",
      citations: [ "page 7", "page 11" ]
    )
    document
  end

  # 40 of 138 pages embedded, which is what the page-progress line reads from.
  def self.mid_embedding
    document = Document.create!(content_hash: SEED_MARKER, status: "embedding", title: "Long Policy.pdf")
    pages(document, 138, embedded: 40)
  end

  def self.expiring_soon
    document = Document.create!(
      content_hash: SEED_MARKER,
      status: "ready", title: "Nearly Gone.pdf",
      summary: "This one is here to watch the countdown finish.",
      expires_at: 70.seconds.from_now
    )
    pages(document, 3, embedded: 3)
  end

  def self.failed_document
    Document.create!(
      content_hash: SEED_MARKER,
      status: "failed", title: "Scanned Leaflet.pdf",
      failure_reason: "We could not find any words in this document. If it is a " \
                      "photo or a scan, please try a version you can select text in."
    )
  end

  def self.with_scan_notes
    document = Document.create!(
      content_hash: SEED_MARKER,
      status: "ready", title: "Council Notice.pdf",
      summary: "It is a notice about a planning application.",
      links: [ "https://www.gov.uk/planning-permission", "mailto:planning@example.gov" ],
      attachments: [ "provenance.xml" ]
    )
    pages(document, 6, embedded: 6)
  end
end
