require "net/http"
require "json"
require "base64"

class ReceiptParserService
  GEMINI_API_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

  class RateLimitError < StandardError; end

  attr_reader :error, :receipt_total

  def initialize(image_path, content_type = "image/jpeg")
    @image_path = image_path
    @content_type = content_type
    @error = nil
    @receipt_total = nil
  end

  def parse
    return [] unless @image_path.present? && File.exist?(@image_path)

    response = call_gemini_api
    parse_response(response)
  rescue RateLimitError => e
    @error = :rate_limit
    Rails.logger.error("ReceiptParserService rate limit: #{e.message}")
    []
  rescue StandardError => e
    Rails.logger.error("ReceiptParserService error: #{e.message}")
    []
  end

  def rate_limited?
    @error == :rate_limit
  end

  private

  def call_gemini_api
    uri = URI("#{GEMINI_API_URL}?key=#{api_key}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = request_body.to_json

    response = http.request(request)
    JSON.parse(response.body)
  end

  def request_body
    {
      contents: [
        {
          parts: [
            { text: prompt },
            {
              inline_data: {
                mime_type: @content_type,
                data: encoded_image
              }
            }
          ]
        }
      ],
      generationConfig: {
        response_mime_type: "application/json"
      },
      systemInstruction: {
        parts: [
          { text: "You are an expert at reading restaurant receipts and extracting itemized data." }
        ]
      }
    }
  end

  def prompt
    <<~PROMPT
      Analyze this restaurant receipt image and extract all line items.
      Return a JSON object with:
      - "items": array of line items
      - "receipt_total": the TOTAL amount shown on the receipt (the final total, including tax if shown)

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
    image_bytes = File.binread(@image_path)
    Base64.strict_encode64(image_bytes)
  end

  def parse_response(response)
    if response["error"]
      error_message = response["error"]["message"] || ""
      error_code = response["error"]["code"]

      # Check for rate limit error (HTTP 429 or quota exceeded message)
      if error_code == 429 || error_message.include?("quota") || error_message.include?("rate")
        raise RateLimitError, error_message
      end

      Rails.logger.error("Gemini API error: #{error_message}")
      return []
    end

    text = response.dig("candidates", 0, "content", "parts", 0, "text")
    return [] unless text

    # Clean up the response in case it has markdown code blocks
    clean_text = text.gsub(/```json\n?/, "").gsub(/```\n?/, "").strip

    parsed = JSON.parse(clean_text)

    # Handle new format with receipt_total and items
    if parsed.is_a?(Hash) && parsed["items"]
      @receipt_total = parsed["receipt_total"].to_f.round(2) if parsed["receipt_total"]
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
    Rails.logger.error("Failed to parse Gemini response: #{e.message}, text: #{text}")
    []
  end

  def api_key
    ENV["GEMINI_API_KEY"] || Rails.application.credentials.dig(:gemini, :api_key)
  end
end