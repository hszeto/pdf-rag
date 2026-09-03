# Catches anything the per-document deletions missed.
#
# Each document schedules its own removal, but a queue can lose a job — a
# restart at the wrong moment, a Redis flush, a bug. Those documents are already
# invisible to the app because every read scopes to `live`; without a sweep they
# would simply sit on disk forever.
#
# Run periodically. There is no scheduler in this app, so `bin/rails
# retention:sweep` is the hook for cron or a platform scheduler.
class SweepExpiredDocumentsJob < ApplicationJob
  queue_as :default

  # A blob is briefly unattached between being uploaded and being attached to a
  # document, so only ones old enough to have missed that window are swept.
  ORPHAN_GRACE = Document::RETENTION

  def perform
    remove_expired_documents
    remove_orphaned_files
  end

  private
    def remove_expired_documents
      count = Document.expired.count
      return if count.zero?

      Document.expired.find_each(&:remove!)
      Rails.logger.info("[retention] swept #{count} expired document(s)")
    end

    # Files whose document is gone but which were never purged — the residue of
    # a deletion that did not finish. Without this the row disappears while the
    # uploaded document stays on disk, which is exactly what the hour is meant
    # to prevent.
    def remove_orphaned_files
      orphans = ActiveStorage::Blob.unattached.where(created_at: ..ORPHAN_GRACE.ago)
      count = orphans.count
      return if count.zero?

      orphans.find_each(&:purge)
      Rails.logger.info("[retention] purged #{count} orphaned file(s)")
    end
end
