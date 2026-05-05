class DiffReceiptsCleanupJob < ApplicationJob
  queue_as :maintenance

  # Default: keep 30 days of diff receipts. Override in config/recurring.yml
  # via the `args:` key (e.g. `args: [60]` to keep 60 days instead).
  def perform(retain_days = 30)
    diff_dir = Rails.root.join("storage", "diff_receipts")
    return unless Dir.exist?(diff_dir)

    cutoff = retain_days.to_i.days.ago
    deleted = 0
    bytes_freed = 0

    Dir.glob(diff_dir.join("*")).each do |path|
      stat = File.stat(path)
      next unless stat.file?
      next if stat.mtime > cutoff

      bytes_freed += stat.size
      File.delete(path)
      deleted += 1
    end

    Rails.logger.info(
      "[DiffReceiptsCleanupJob] removed #{deleted} files older than " \
      "#{retain_days}d (freed #{(bytes_freed / 1024.0 / 1024.0).round(1)} MB)"
    )
  end
end
