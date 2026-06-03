require "net/http"
require "json"

class TelegramNotifierService
  TELEGRAM_API_BASE = "https://api.telegram.org".freeze

  # Telegram API limits: photo captions max 1024 chars, text messages max 4096.
  CAPTION_LIMIT = 1024
  MESSAGE_LIMIT = 4096

  def initialize
    @bot_token = ENV["TELEGRAM_BOT_TOKEN"]
    @chat_id = ENV["TELEGRAM_NOTIFY_CHAT_ID"]
  end

  def send_screenshot(image_path:, caption: "📸 Parsed receipt result")
    return unless configured?
    return unless image_path && File.exist?(image_path)

    send_photo(image_path, "image/png", caption)
  rescue StandardError => e
    Rails.logger.error("TelegramNotifierService screenshot error: #{e.message}")
  end

  def notify_receipt_parsed(items:, receipt_total:, restaurant_name:, image_path:, content_type:, request_info: {})
    return unless configured?

    message = build_message(items, receipt_total, restaurant_name, request_info)

    if image_path && File.exist?(image_path)
      if message.length <= CAPTION_LIMIT
        send_photo(image_path, content_type, message)
      else
        # Long receipts blow past the 1024-char caption limit. Attach a short
        # summary to the photo and send the full itemized breakdown as a
        # separate text message (4096-char limit).
        send_photo(image_path, content_type, build_summary_caption(items, receipt_total, restaurant_name))
        send_message(message)
      end
    else
      send_message(message)
    end
  rescue StandardError => e
    Rails.logger.error("TelegramNotifierService error: #{e.message}")
  end

  private

  def configured?
    @bot_token.present? && @chat_id.present?
  end

  def build_message(items, receipt_total, restaurant_name, request_info)
    lines = []
    lines << "🧾 <b>New receipt parsed!</b>"
    lines << ""
    lines << "🏪 <b>#{escape_html(restaurant_name)}</b>" if restaurant_name.present?

    # Items
    items.each do |item|
      prefix = item[:is_modifier] ? "  ↳ " : "• "
      lines << "#{prefix}#{escape_html(item[:name])} — $#{'%.2f' % item[:price]}"
    end

    lines << ""
    subtotal = items.sum { |i| i[:price].to_f }
    lines << "💰 <b>Items total:</b> $#{'%.2f' % subtotal}"
    lines << "🧾 <b>Receipt total:</b> $#{'%.2f' % receipt_total}" if receipt_total

    # Alert on difference
    if receipt_total && receipt_total > 0
      difference = (receipt_total - subtotal).abs
      if difference >= 1.0
        lines << ""
        lines << "⚠️ <b>DIFERENCIA: $#{'%.2f' % difference}</b> — totals don't match!"
      end
    end

    # Request info
    if request_info[:ip].present?
      lines << ""
      lines << "🌐 IP: <code>#{escape_html(request_info[:ip])}</code>"
      lines << "📱 UA: <code>#{escape_html(request_info[:user_agent].to_s.truncate(100))}</code>" if request_info[:user_agent].present?
    end

    lines << ""
    lines << "⏰ #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"

    lines.join("\n")
  end

  # Compact, bounded caption (no per-item lines) for when the full breakdown is
  # too long to fit in a photo caption. Stays well under CAPTION_LIMIT.
  def build_summary_caption(items, receipt_total, restaurant_name)
    lines = []
    lines << "🧾 <b>New receipt parsed!</b>"
    lines << "🏪 <b>#{escape_html(restaurant_name)}</b>" if restaurant_name.present?

    subtotal = items.sum { |i| i[:price].to_f }
    lines << "💰 <b>Items total:</b> $#{'%.2f' % subtotal} (#{items.count} items)"
    lines << "🧾 <b>Receipt total:</b> $#{'%.2f' % receipt_total}" if receipt_total

    if receipt_total && receipt_total > 0
      difference = (receipt_total - subtotal).abs
      lines << "⚠️ <b>DIFERENCIA: $#{'%.2f' % difference}</b> — totals don't match!" if difference >= 1.0
    end

    lines << ""
    lines << "📝 Detalle completo en el siguiente mensaje."
    lines.join("\n")
  end

  def send_photo(image_path, content_type, caption)
    uri = URI("#{TELEGRAM_API_BASE}/bot#{@bot_token}/sendPhoto")

    # Determine filename and mime type
    ext = case content_type
          when /png/ then ".png"
          when /gif/ then ".gif"
          when /webp/ then ".webp"
          else ".jpg"
          end

    boundary = "----RubyBoundary#{SecureRandom.hex(8)}"

    body = build_multipart_body(boundary, image_path, "receipt#{ext}", content_type, caption)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = body

    response = http.request(request)
    parsed = JSON.parse(response.body)

    if parsed["ok"]
      Rails.logger.info("TelegramNotifierService: Photo sent successfully!")
    else
      Rails.logger.error("Telegram sendPhoto failed: #{parsed['description']}")
    end

    parsed
  end

  def send_message(text)
    text = clamp_to_message_limit(text)
    uri = URI("#{TELEGRAM_API_BASE}/bot#{@bot_token}/sendMessage")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = {
      chat_id: @chat_id,
      text: text,
      parse_mode: "HTML"
    }.to_json

    response = http.request(request)
    JSON.parse(response.body)
  end

  # Keep a text message under the 4096-char limit. Truncate on a line boundary
  # so we never cut through an HTML tag (which Telegram would reject).
  def clamp_to_message_limit(text)
    return text if text.length <= MESSAGE_LIMIT

    suffix = "\n…(truncado)"
    budget = MESSAGE_LIMIT - suffix.length
    cut = text[0, budget]
    cut = cut[0, cut.rindex("\n") || cut.length]
    cut + suffix
  end

  def build_multipart_body(boundary, file_path, filename, content_type, caption)
    body = "".b  # Force binary encoding

    # chat_id field
    body << "--#{boundary}\r\n".b
    body << "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".b
    body << "#{@chat_id}\r\n".b

    # caption field
    body << "--#{boundary}\r\n".b
    body << "Content-Disposition: form-data; name=\"caption\"\r\n\r\n".b
    body << caption.encode("UTF-8").b
    body << "\r\n".b

    # parse_mode field
    body << "--#{boundary}\r\n".b
    body << "Content-Disposition: form-data; name=\"parse_mode\"\r\n\r\n".b
    body << "HTML\r\n".b

    # photo field
    body << "--#{boundary}\r\n".b
    body << "Content-Disposition: form-data; name=\"photo\"; filename=\"#{filename}\"\r\n".b
    body << "Content-Type: #{content_type}\r\n\r\n".b
    body << File.binread(file_path)
    body << "\r\n".b

    body << "--#{boundary}--\r\n".b
    body
  end

  def escape_html(text)
    text.to_s
      .gsub("&", "&amp;")
      .gsub("<", "&lt;")
      .gsub(">", "&gt;")
  end
end
