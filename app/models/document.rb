class Document < ApplicationRecord
# Screening happens before a Document exists, so anything with a record here
# has already been judged safe to open.
has_one_attached :file

  # Removes the row, its passages and the uploaded bytes, in that order and
  # without deferring any of it.
  #
  # Active Storage's default is purge_later, which enqueues a second job to
  # delete the file. For a retention promise that is too weak a guarantee: if
  # that job is lost the record is gone while the document is still sitting on
  # disk, which is precisely the thing the retention window is supposed to prevent.
  def remove!
    file.purge
    destroy!
  end
  has_many :chunks, class_name: "DocumentChunk", dependent: :destroy
  has_many :messages, dependent: :destroy

  # Written in the unit readers should be told about: the copy derives from this
  # constant rather than repeating it, so the two can never drift apart.
  RETENTION = 30.minutes

  STATUSES = %w[pending extracting embedding summarizing ready failed].freeze
  validates :status, inclusion: { in: STATUSES }

  before_validation :set_expiry, on: :create

  # Retention is a property of the data, not a promise the sweep job keeps.
  # Every read goes through this, so a document past its window is invisible even
  # if nothing has deleted it yet.
  scope :live, -> { where(expires_at: Time.current..) }
  scope :expired, -> { where(expires_at: ..Time.current) }
  scope :ready, -> { where(status: "ready") }

  STATUSES.each do |state|
    define_method("#{state}?") { status == state }
  end

  def processing? = %w[pending extracting embedding summarizing].include?(status)

  def fail!(reason)
    update!(status: "failed", failure_reason: reason)
  end

  def chunks_awaiting_embedding = chunks.where(embedding: nil)

  # How far reading has got, told in pages because that is a property of the
  # reader's document rather than of how we cut it up (R1.4).
  #
  # Both are nil until the number is real, and the screen shows nothing until
  # both are: during `extracting` no chunks exist, and between the rows being
  # written and the first batch returning nothing is embedded yet. That one
  # rule also covers chunks carrying no page at all, which would otherwise
  # render "page  of ".
  #
  # The total is the last page that produced text, so a document ending in
  # blank or image-only pages reports fewer pages than the PDF holds. That is
  # honest about what was read, which is all the line claims.
  def page_count = chunks.maximum(:page)
  def pages_read = chunks.embedded.maximum(:page)

  private
    def set_expiry
      self.expires_at ||= RETENTION.from_now
    end
end
