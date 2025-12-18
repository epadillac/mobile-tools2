class SplitChecksController < ApplicationController
  layout "split_checks"
  # before_action :authenticate_with_password
  skip_forgery_protection if: -> { hotwire_native_app? }

  def new
  end

  def create
    @receipt_image = params[:receipt_image]
    result = parse_receipt_items

    if result[:rate_limited]
      flash.now[:alert] = "Service is busy. Please wait about a minute and try again."
      render :new, status: :too_many_requests
    elsif result[:items].empty?
      flash.now[:alert] = "Could not parse receipt. Please try again with a clearer image."
      render :new, status: :unprocessable_entity
    else
      @items = result[:items]
      @receipt_total = result[:receipt_total]
      @restaurant_name = result[:restaurant_name]

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

  private

  def parse_receipt_items
    return { items: sample_items, rate_limited: false, receipt_total: nil } unless @receipt_image.present?

    # Get the tempfile path from the uploaded file
    image_path = @receipt_image.tempfile.path
    content_type = @receipt_image.content_type || "image/jpeg"

    # Try Claude (Anthropic) first
    claude_service = ClaudeReceiptParserService.new(image_path, content_type)
    items = claude_service.parse
    receipt_total = claude_service.receipt_total
    restaurant_name = claude_service.restaurant_name

    # If Claude is rate limited, try Gemini as fallback
    if claude_service.rate_limited?
      Rails.logger.info("Claude rate limited, falling back to Gemini")
      gemini_service = ReceiptParserService.new(image_path, content_type)
      items = gemini_service.parse
      receipt_total = gemini_service.receipt_total
      restaurant_name = nil # Gemini doesn't support restaurant name yet

      # If Gemini is also rate limited, return rate limit error
      if gemini_service.rate_limited?
        return { items: [], rate_limited: true, receipt_total: nil, restaurant_name: nil }
      end
    end

    {
      items: items.presence || [],
      rate_limited: false,
      receipt_total: receipt_total,
      restaurant_name: restaurant_name
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
end