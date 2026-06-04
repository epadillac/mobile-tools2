class SplitChecksController < ApplicationController
  layout "split_checks"
  # before_action :authenticate_with_password
  skip_forgery_protection

  def new; end

  def create
    @receipt_image = params[:receipt_image]

    # No image → the instant demo/sample path. Nothing slow to do, so store the
    # result directly and go straight to the result page.
    unless @receipt_image.present?
      store_receipt(status: "ready", items: sample_items, receipt_total: nil, restaurant_name: nil)
      redirect_to split_check_path(id: "current") and return
    end

    # Parsing a real receipt can take ~90s (Gemini), which trips proxy/Cloudflare
    # timeouts if done in the request. Hand it to a background job, mark the
    # result "processing", and redirect immediately. The show page polls #status.
    token = SecureRandom.uuid
    session[:receipt_token] = token

    image_path = persist_upload(@receipt_image, token)
    Rails.cache.write(receipt_cache_key(token), { status: "processing" }, expires_in: 1.hour)

    ReceiptParseJob.perform_later(
      token: token,
      image_path: image_path,
      content_type: @receipt_image.content_type || "image/jpeg",
      original_filename: @receipt_image.original_filename,
      request_ip: request.remote_ip,
      request_ua: request.user_agent
    )

    redirect_to split_check_path(id: "current")
  end

  def show
    data = read_receipt

    case data && data[:status]
    when "ready"
      @items = data[:items].map(&:symbolize_keys)
      @receipt_total = data[:receipt_total]
      @restaurant_name = data[:restaurant_name]
    when "processing"
      render :processing
    when "error"
      flash.now[:alert] = error_message_for(data[:reason])
      render :new, status: :unprocessable_entity
    else
      redirect_to new_split_check_path
    end
  end

  # Polled by the processing page until the background parse finishes.
  def status
    data = read_receipt
    render json: { status: data ? data[:status] : "missing", reason: data && data[:reason] }
  end

  def demo
    @items = sample_items
    render :show
  end

  def manual; end

  private

  def receipt_cache_key(token)
    "split_check:receipt:#{token}"
  end

  def read_receipt
    return nil if session[:receipt_token].blank?
    Rails.cache.read(receipt_cache_key(session[:receipt_token]))
  end

  def store_receipt(payload)
    session[:receipt_token] = SecureRandom.uuid
    Rails.cache.write(receipt_cache_key(session[:receipt_token]), payload, expires_in: 1.hour)
  end

  # Copy the uploaded tempfile somewhere durable: the request's tempfile is
  # cleaned up once we redirect, but the background job needs to read it later.
  def persist_upload(upload, token)
    dir = Rails.root.join("tmp", "receipt_uploads")
    FileUtils.mkdir_p(dir)
    ext = File.extname(upload.original_filename.to_s).presence || ".jpg"
    dest = dir.join("#{token}#{ext}")
    FileUtils.cp(upload.tempfile.path, dest)
    dest.to_s
  end

  def error_message_for(reason)
    case reason
    when "rate_limited"
      "El servicio está ocupado. Por favor espera aproximadamente un minuto e inténtalo de nuevo."
    when "overloaded"
      "El servicio de IA está saturado en este momento. La imagen está bien, solo intenta de nuevo en unos segundos."
    else
      "No se pudo procesar el ticket. Por favor inténtalo de nuevo con una imagen más clara."
    end
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

  def via_tunnel?
    host = request.host.to_s
    host.include?('ngrok') || host.include?('trycloudflare')
  end
end