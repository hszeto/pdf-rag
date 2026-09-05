# How much the app is being used, kept after the documents themselves are gone.
#
# Nothing here describes a document: no filename, no title, no token, no text.
# A row is a size, a moment, and an unlinkable daily hash — which is why the
# retention promise made to readers stays true (D6).
class UsageEvent < ApplicationRecord
  KINDS = %w[upload refusal].freeze

  validates :kind, inclusion: { in: KINDS }

  scope :uploads, -> { where(kind: "upload") }
  scope :refusals, -> { where(kind: "refusal") }

  class << self
    def record_upload(byte_size:, address:)
      record("upload", address, byte_size: byte_size)
    end

    def record_refusal(address:)
      record("refusal", address)
    end

    # The five figures the endpoint publishes, in the order it publishes them.
    # Sizes describe accepted uploads only — a refusal has no size worth averaging,
    # and a file rejected for being too large would drag the maximum to the limit
    # every time someone tried one.
    def summary
      sizes = uploads.where.not(byte_size: nil)

      {
        uploads: uploads.count,
        visitors: distinct_visitors,
        refusals: refusals.count,
        average_mb: megabytes(sizes.average(:byte_size)),
        maximum_mb: megabytes(sizes.maximum(:byte_size))
      }
    end

    private
      # Distinct hashes, not distinct people: the same visitor on two days is two
      # values, because the key rotates. Counted this way knowingly (D3).
      def distinct_visitors = distinct.count(:visitor_hash)

      def megabytes(bytes) = bytes ? (bytes.to_f / 1.megabyte).round(1) : 0.0

      # Counting must never cost someone their upload. If this row cannot be
      # written the request carries on: the number is worth less than the thing
      # it is counting.
      def record(kind, address, byte_size: nil)
        create!(kind: kind, byte_size: byte_size, visitor_hash: VisitorHash.for(address))
      rescue StandardError => e
        Rails.logger.warn("[usage] could not record #{kind}: #{e.class}: #{e.message}")
        nil
      end
  end
end
