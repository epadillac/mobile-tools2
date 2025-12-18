require "net/http"
require "json"
require "base64"

class ClaudeReceiptParserService
  CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
  # Base64 encoding increases size by ~33%, so 3.5MB raw becomes ~4.7MB encoded (under 5MB limit)
  MAX_IMAGE_SIZE = 1.0 * 1024 * 1024
  MAX_DIMENSION = 2048 # Max width/height for resizing

  class RateLimitError < StandardError; end

  attr_reader :error, :receipt_total, :restaurant_name

  def initialize(image_path, content_type = "image/jpeg")
    @image_path = image_path
    @content_type = content_type
    @error = nil
    @receipt_total = nil
    @restaurant_name = nil
    @compressed_tempfile = nil
  end

  def parse
    return [] unless @image_path.present? && File.exist?(@image_path)

    response = call_claude_api
    parse_response(response)
  rescue RateLimitError => e
    @error = :rate_limit
    Rails.logger.error("ClaudeReceiptParserService rate limit: #{e.message}")
    []
  rescue StandardError => e
    Rails.logger.error("ClaudeReceiptParserService error: #{e.message}")
    []
  end

  def rate_limited?
    @error == :rate_limit
  end

  private

  def call_claude_api
    uri = URI(CLAUDE_API_URL)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE # TODO: Fix SSL certs for production
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = api_key
    request["anthropic-version"] = "2023-06-01"
    request.body = request_body.to_json

    response = http.request(request)
    JSON.parse(response.body)
  end

  def request_body
    {
      model: "claude-sonnet-4-20250514",
      max_tokens: 4096,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              source: {
                type: "base64",
                media_type: media_type,
                data: encoded_image
              }
            },
            {
              type: "text",
              text: prompt
            }
          ]
        }
      ]
    }
  end

  def media_type
    case @content_type
    when /jpeg|jpg/i
      "image/jpeg"
    when /png/i
      "image/png"
    when /gif/i
      "image/gif"
    when /webp/i
      "image/webp"
    else
      "image/jpeg"
    end
  end

  def prompt
    <<~PROMPT
      Analyze this restaurant receipt image and extract all line items.
      Return a JSON object with:
      - "restaurant_name": the name of the restaurant/business (short, clean name - e.g., "Encanto Cafe", "Wild Rooster", "Starbucks")
      - "items": array of line items
      - "receipt_total": the TOTAL amount shown on the receipt (the final total, including tax if shown)

      For "restaurant_name":
      - Look at the TOP of the receipt for the business name (usually in larger text or the first line)
      - Extract a SHORT, CLEAN name (2-4 words max)
      - Examples: "ENCANTO RESTAURANTE CAFE" → "Encanto Cafe", "WILD ROOSTER CAFE BAR" → "Wild Rooster"
      - Remove words like "RESTAURANTE", "S.A. DE C.V.", "RFC:", addresses, etc.
      - If unclear, return null

      Each item in the "items" array should have:
      - "name": the item name (string)
      - "quantity": always set to 1 (we use line totals, not unit prices)
      - "price": the LINE TOTAL price shown on the receipt (number, without currency symbol)
      - "is_modifier": true if this is a modifier/add-on to the previous item (like extra ingredients, milk type, etc.), false if it's a main item

      CRITICAL RULES:
      1. The "price" field should be the TOTAL AMOUNT shown on that line of the receipt.
         - If receipt shows "2 LATTE $130.00", return quantity: 1, price: 130.00 (the line total)
         - Do NOT multiply quantity by price - the receipt already shows the line total
      2. Always set quantity to 1 since we're using the line total price.
      3. Each item's name MUST be paired with the price that appears on the SAME LINE of the receipt.
      4. ONLY include lines where BOTH an item name AND a price appear together on the same row.
      5. COMPLETELY SKIP any line that does not have a price number on it, including:
         - Cooking instructions (e.g., "Medium Well", "No Ice", "Extra Hot")
         - Preparation notes (e.g., "See Server", "N/A")
         - Sub-item descriptions (e.g., "Agua Natural" appearing below a drink without its own price)
      6. Do NOT shift prices from one item to another.
      7. For "receipt_total", look for the final TOTAL line on the receipt (may be labeled "TOTAL:", "Total", etc.)
      8. IMPORTANT: Include ALL items with prices, even if the same item name appears multiple times on the receipt.
         - For example, if "LECHE COCO $10.00" appears twice on the receipt (once under LATTE, once under BEBIDA), include BOTH entries.
         - Each line with a price should be a separate entry in the items array.

      Do NOT include subtotals, tax (IVA), tips in the items array.

      Example - if receipt shows:
        ENCANTO RESTAURANTE CAFE
        AMANDA MONSERRATE ACOSTA
        RFC:...
        ...
        CANT. DESCRIPCION              IMPORTE
        1     Limonada                  66.00
              Agua Natural
        2     Latte                    130.00
              Leche Deslactosada        10.00
        1     Bohemia Obs               74.00
        ================================
        TOTAL:                        $280.00

      Return:
      {
        "restaurant_name": "Encanto Cafe",
        "receipt_total": 280.00,
        "items": [
          {"name": "Limonada", "quantity": 1, "price": 66.00, "is_modifier": false},
          {"name": "Latte", "quantity": 1, "price": 130.00, "is_modifier": false},
          {"name": "Leche Deslactosada", "quantity": 1, "price": 10.00, "is_modifier": true},
          {"name": "Bohemia Obs", "quantity": 1, "price": 74.00, "is_modifier": false}
        ]
      }

      Return ONLY the JSON object, no other text.
    PROMPT
  end

  def encoded_image
    image_path = compress_image_if_needed
    image_bytes = File.binread(image_path)
    Base64.strict_encode64(image_bytes)
  end

  def compress_image_if_needed
    file_size = File.size(@image_path)

    if file_size <= MAX_IMAGE_SIZE
      Rails.logger.info("Image size OK: #{(file_size / 1024.0 / 1024.0).round(2)}MB")
      return @image_path
    end

    Rails.logger.info("Image too large (#{(file_size / 1024.0 / 1024.0).round(2)}MB), compressing...")

    require "image_processing/mini_magick"

    # Create a tempfile for the compressed image
    @compressed_tempfile = Tempfile.new([ "compressed_receipt", ".jpg" ])

    # Start with resize and moderate quality
    quality = 60
    result_path = nil

    loop do
      pipeline = ImageProcessing::MiniMagick
        .source(@image_path)
        .resize_to_limit(MAX_DIMENSION, MAX_DIMENSION)
        .saver(quality: quality)
        .call(destination: @compressed_tempfile.path)

      result_size = File.size(@compressed_tempfile.path)
      Rails.logger.info("Compressed to #{(result_size / 1024.0 / 1024.0).round(2)}MB at quality #{quality}")

      if result_size <= MAX_IMAGE_SIZE || quality <= 40
        result_path = @compressed_tempfile.path
        break
      end

      # Reduce quality and try again
      quality -= 15
    end

    result_path
  end

  def parse_response(response)
    if response["error"]
      error_message = response.dig("error", "message") || ""
      error_type = response.dig("error", "type") || ""

      # Check for rate limit error
      if error_type == "rate_limit_error" || error_message.include?("rate") || error_message.include?("quota")
        raise RateLimitError, error_message
      end

      Rails.logger.error("Claude API error: #{error_message}")
      return []
    end

    text = response.dig("content", 0, "text")
    return [] unless text

    # Clean up the response in case it has markdown code blocks
    clean_text = text.gsub(/```json\n?/, "").gsub(/```\n?/, "").strip

    parsed = JSON.parse(clean_text)

    # Handle new format with receipt_total, restaurant_name and items
    if parsed.is_a?(Hash) && parsed["items"]
      @receipt_total = parsed["receipt_total"].to_f.round(2) if parsed["receipt_total"]
      @restaurant_name = parsed["restaurant_name"].to_s.strip.presence if parsed["restaurant_name"]
      items_array = parsed["items"]
    else
      # Fallback for old array format
      items_array = parsed
    end

    items_array.map do |item|
      {
        name: (item["name"] || item["item"]).to_s,
        quantity: item["quantity"].to_i.clamp(1, 100),
        price: item["price"].to_f.round(2),
        is_modifier: item["is_modifier"] == true
      }
    end
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse Claude response: #{e.message}, text: #{text}")
    []
  end

  def api_key
    ENV["ANTHROPIC_API_KEY"] || Rails.application.credentials.dig(:anthropic, :api_key)
  end
end