class SplitChecksController < ApplicationController
  layout "split_checks"
  # before_action :authenticate_with_password
  skip_forgery_protection

  def new; end

  def create
    @receipt_image = params[:receipt_image]
    result = parse_receipt_items

    if result[:rate_limited]
      flash.now[:alert] = "El servicio está ocupado. Por favor espera aproximadamente un minuto e inténtalo de nuevo."
      render :new, status: :too_many_requests
    elsif result[:overloaded]
      flash.now[:alert] = "El servicio de IA está saturado en este momento. La imagen está bien, solo intenta de nuevo en unos segundos."
      render :new, status: :service_unavailable
    elsif result[:items].empty?
      flash.now[:alert] = "No se pudo procesar el ticket. Por favor inténtalo de nuevo con una imagen más clara."
      render :new, status: :unprocessable_entity
    else
      @items = result[:items]
      @receipt_total = result[:receipt_total]
      @restaurant_name = result[:restaurant_name]
      @optimized_image_path = result[:optimized_image_path]

      # Save receipt if there's a diff for future test development
      save_diff_receipt(@optimized_image_path, @items, @receipt_total, @restaurant_name)

      # Notify via Telegram
      notify_telegram_receipt_parsed(@items, @receipt_total, @restaurant_name)

      # Cache in session for page reloads
      session[:receipt_items] = @items
      session[:receipt_total] = @receipt_total
      session[:restaurant_name] = @restaurant_name

      redirect_to split_check_path(id: "current")
    end
  end

  def show
    if session[:receipt_items].present?
      @items = session[:receipt_items].map(&:symbolize_keys)
      @receipt_total = session[:receipt_total]
      @restaurant_name = session[:restaurant_name]
    else
      redirect_to new_split_check_path and return
    end
  end

  def demo
    @items = sample_items
    render :show
  end

  def manual; end

  private

  def parse_receipt_items
    return { items: sample_items, rate_limited: false, receipt_total: nil } unless @receipt_image.present?

    # Get the tempfile path from the uploaded file
    image_path = @receipt_image.tempfile.path
    content_type = @receipt_image.content_type || "image/jpeg"

    # Use Gemini directly (Claude disabled)
    gemini_service = ReceiptParserService.new(image_path, content_type)
    items = gemini_service.parse
    receipt_total = gemini_service.receipt_total
    restaurant_name = gemini_service.restaurant_name

    if gemini_service.rate_limited?
      return { items: [], rate_limited: true, overloaded: false, receipt_total: nil, restaurant_name: nil }
    end

    if gemini_service.overloaded?
      return { items: [], rate_limited: false, overloaded: true, receipt_total: nil, restaurant_name: nil }
    end

    {
      items: items.presence || [],
      rate_limited: false,
      overloaded: false,
      receipt_total: receipt_total,
      restaurant_name: restaurant_name,
      optimized_image_path: gemini_service.image_path
    }
  end

  def sample_items
    [
      { name: "Pumpkin Hot Cakes", quantity: 1, price: 159.00, is_modifier: false },
      { name: "Latte (2)", quantity: 1, price: 130.00, is_modifier: false },
      { name: "Leche Deslactosada", quantity: 1, price: 10.00, is_modifier: true },
      { name: "Leche Coco", quantity: 1, price: 10.00, is_modifier: true },
      { name: "Esencia Vainilla (2.0x)", quantity: 1, price: 20.00, is_modifier: true },
      { name: "Machaca", quantity: 1, price: 169.00, is_modifier: false },
      { name: "Bebida 39.90", quantity: 1, price: 39.90, is_modifier: false },
      { name: "Leche Coco", quantity: 1, price: 10.00, is_modifier: true },
      { name: "Esencia Vainilla", quantity: 1, price: 10.00, is_modifier: true }
    ]
  end

  def notify_telegram_receipt_parsed(items, receipt_total, restaurant_name)
    return unless @optimized_image_path.present? && File.exist?(@optimized_image_path)

    # Copy optimized image since tempfile may be cleaned up after redirect
    temp_copy = Tempfile.new(["receipt_notify", ".jpg"])
    FileUtils.cp(@optimized_image_path, temp_copy.path)

    request_ip = request.remote_ip
    request_ua = request.user_agent
    content_type = "image/jpeg"

    Thread.new do
      begin
        # Take screenshot of parsed result
        screenshot_path = ReceiptScreenshotService.new(
          items: items,
          receipt_total: receipt_total,
          restaurant_name: restaurant_name
        ).capture

        # Send receipt image + text notification
        TelegramNotifierService.new.notify_receipt_parsed(
          items: items,
          receipt_total: receipt_total,
          restaurant_name: restaurant_name,
          image_path: temp_copy.path,
          content_type: content_type,
          request_info: {
            ip: request_ip,
            user_agent: request_ua
          }
        )

        # Send screenshot as a second message if available
        if screenshot_path && File.exist?(screenshot_path)
          TelegramNotifierService.new.send_screenshot(
            image_path: screenshot_path,
            caption: "📸 Parsed result for #{restaurant_name || 'receipt'}"
          )
          File.delete(screenshot_path) rescue nil
        end
      rescue StandardError => e
        Rails.logger.error("Telegram notification thread error: #{e.message}")
      ensure
        temp_copy.close
        temp_copy.unlink
      end
    end
  rescue StandardError => e
    Rails.logger.error("Telegram notification failed: #{e.message}")
  end

  def save_diff_receipt(image_path, items, receipt_total, restaurant_name)
    return unless image_path.present? && File.exist?(image_path) && receipt_total.present? && items.any?

    items_sum = items.sum { |item| item[:price].to_f }
    difference = (receipt_total - items_sum).abs.round(2)

    # Only save if there's a meaningful difference
    return if difference < 0.01

    diff_dir = Rails.root.join("storage", "diff_receipts")
    FileUtils.mkdir_p(diff_dir)

    # Generate a timestamped filename based on restaurant name
    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    safe_name = (restaurant_name || "unknown").downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
    base_name = "#{timestamp}_#{safe_name}"

    # Save the optimized receipt image
    dest_path = diff_dir.join("#{base_name}.jpg")
    FileUtils.cp(image_path, dest_path)

    # Save metadata JSON with parsed data and diff info
    metadata = {
      saved_at: Time.current.iso8601,
      restaurant_name: restaurant_name,
      receipt_total: receipt_total,
      items_sum: items_sum.round(2),
      difference: difference,
      item_count: items.count,
      items: items,
      original_filename: @receipt_image&.original_filename,
      content_type: "image/jpeg"
    }

    metadata_path = diff_dir.join("#{base_name}.json")
    File.write(metadata_path, JSON.pretty_generate(metadata))

    Rails.logger.info("Saved diff receipt: #{base_name} (diff: $#{difference})")
  rescue StandardError => e
    Rails.logger.error("Failed to save diff receipt: #{e.message}")
  end

  def authenticate_with_password
    return if hotwire_native_app?

    expected_password = ENV.fetch("SPLIT_CHECK_PASSWORD", "changeme")

    authenticate_or_request_with_http_basic("Dividir Cuenta") do |_username, password|
      ActiveSupport::SecurityUtils.secure_compare(password, expected_password)
    end
  end

  def iphone_user_agent?
    user_agent = request.user_agent.to_s
    user_agent.match?(/iPhone/i)
  end

  def via_tunnel?
    host = request.host.to_s
    host.include?('ngrok') || host.include?('trycloudflare')
  end
end