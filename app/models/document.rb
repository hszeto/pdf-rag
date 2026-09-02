class Document < ApplicationRecord
  # Screening happens before a Document exists, so anything with a record here
  # has already been judged safe to open.
  has_one_attached :file
  has_many :chunks, class_name: "DocumentChunk", dependent: :destroy

  RETENTION = 1.hour

  STATUSES = %w[pending extracting embedding ready failed].freeze
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

  def processing? = %w[pending extracting embedding].include?(status)

  def fail!(reason)
    update!(status: "failed", failure_reason: reason)
  end

  def chunks_awaiting_embedding = chunks.where(embedding: nil)

  private
    def set_expiry
      self.expires_at ||= RETENTION.from_now
    end
end
