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
  # disk, which is precisely the thing the hour is supposed to prevent.
  def remove!
    file.purge
    destroy!
  end
  has_many :chunks, class_name: "DocumentChunk", dependent: :destroy
  has_many :messages, dependent: :destroy

  RETENTION = 1.hour

  STATUSES = %w[pending extracting embedding summarizing ready failed].freeze
  validates :status, inclusion: { in: STATUSES }

  before_validation :set_expiry, on: :create

  # Retention is a property of the data, not a promise the sweep job keeps.
  # Every read goes through this, so a document past its hour is invisible even
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

  private
    def set_expiry
      self.expires_at ||= RETENTION.from_now
    end
end
