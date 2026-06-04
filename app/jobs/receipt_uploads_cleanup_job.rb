class ReceiptUploadsCleanupJob < ApplicationJob
  queue_as :maintenance

  # ReceiptParseJob deletes each upload as soon as it finishes, so anything left
  # in tmp/receipt_uploads is an orphan from a job that errored or never ran.
  # Default: sweep files older than 6 hours. Override via config/recurring.yml
  # `args:` (e.g. `args: [24]` to keep 24 hours instead).
  def perform(retain_hours = 6)
    upload_dir = Rails.root.join("tmp", "receipt_uploads")
    return unless Dir.exist?(upload_dir)

    cutoff = retain_hours.to_i.hours.ago
    deleted = 0
    bytes_freed = 0

    Dir.glob(upload_dir.join("*")).each do |path|
      stat = File.stat(path)
      next unless stat.file?
      next if stat.mtime > cutoff

      bytes_freed += stat.size
      File.delete(path)
      deleted += 1
    end

    Rails.logger.info(
      "[ReceiptUploadsCleanupJob] removed #{deleted} orphaned uploads older than " \
      "#{retain_hours}h (freed #{(bytes_freed / 1024.0 / 1024.0).round(1)} MB)"
    )
  end
end
