require "fileutils"

# Parses an uploaded receipt off the request cycle so the web request returns
# instantly (the synchronous Gemini parse could take ~90s and trip proxy/
# Cloudflare timeouts). Writes the result into Rails.cache under the same token
# the controller stored in the session; the show page polls #status until ready.
class ReceiptParseJob < ApplicationJob
  queue_as :default

  CACHE_TTL = 1.hour

  def perform(token:, image_path:, content_type:, original_filename: nil, request_ip: nil, request_ua: nil)
    service = ReceiptParserService.new(image_path, content_type)
    items = service.parse
    receipt_total = service.receipt_total
    restaurant_name = service.restaurant_name
    optimized_image_path = service.image_path

    if service.rate_limited?
      write_status(token, status: "error", reason: "rate_limited")
      return
    elsif service.overloaded?
      write_status(token, status: "error", reason: "overloaded")
      return
    elsif items.blank?
      write_status(token, status: "error", reason: "empty")
      return
    end

    write_status(
      token,
      status: "ready",
      items: items,
      receipt_total: receipt_total,
      restaurant_name: restaurant_name
    )

    save_diff_receipt(optimized_image_path, items, receipt_total, restaurant_name, original_filename)
    notify_telegram(items, receipt_total, restaurant_name, optimized_image_path, request_ip, request_ua)
  rescue StandardError => e
    Rails.logger.error("ReceiptParseJob error: #{e.message}")
    write_status(token, status: "error", reason: "exception")
  ensure
    File.delete(image_path) if image_path.present? && File.exist?(image_path)
  end

  private

  def write_status(token, payload)
    Rails.cache.write("split_check:receipt:#{token}", payload, expires_in: CACHE_TTL)
  end

  # Notify Telegram with the parsed result + a screenshot (mirrors the previous
  # inline controller behavior, now that parsing runs in the job).
  def notify_telegram(items, receipt_total, restaurant_name, image_path, request_ip, request_ua)
    return unless image_path.present? && File.exist?(image_path)

    screenshot_path = ReceiptScreenshotService.new(
      items: items,
      receipt_total: receipt_total,
      restaurant_name: restaurant_name
    ).capture

    TelegramNotifierService.new.notify_receipt_parsed(
      items: items,
      receipt_total: receipt_total,
      restaurant_name: restaurant_name,
      image_path: image_path,
      content_type: "image/jpeg",
      request_info: { ip: request_ip, user_agent: request_ua }
    )

    if screenshot_path && File.exist?(screenshot_path)
      TelegramNotifierService.new.send_screenshot(
        image_path: screenshot_path,
        caption: "📸 Parsed result for #{restaurant_name || 'receipt'}"
      )
      File.delete(screenshot_path) rescue nil
    end
  rescue StandardError => e
    Rails.logger.error("ReceiptParseJob Telegram notification failed: #{e.message}")
  end

  # Saves receipts whose items don't sum to the printed total, for test fixtures.
  def save_diff_receipt(image_path, items, receipt_total, restaurant_name, original_filename)
    return unless image_path.present? && File.exist?(image_path) && receipt_total.present? && items.any?

    items_sum = items.sum { |item| item[:price].to_f }
    difference = (receipt_total - items_sum).abs.round(2)
    return if difference < 0.01

    diff_dir = Rails.root.join("storage", "diff_receipts")
    FileUtils.mkdir_p(diff_dir)

    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    safe_name = (restaurant_name || "unknown").downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
    base_name = "#{timestamp}_#{safe_name}"

    FileUtils.cp(image_path, diff_dir.join("#{base_name}.jpg"))

    metadata = {
      saved_at: Time.current.iso8601,
      restaurant_name: restaurant_name,
      receipt_total: receipt_total,
      items_sum: items_sum.round(2),
      difference: difference,
      item_count: items.count,
      items: items,
      original_filename: original_filename,
      content_type: "image/jpeg"
    }
    File.write(diff_dir.join("#{base_name}.json"), JSON.pretty_generate(metadata))

    Rails.logger.info("Saved diff receipt: #{base_name} (diff: $#{difference})")
  rescue StandardError => e
    Rails.logger.error("Failed to save diff receipt: #{e.message}")
  end
end
