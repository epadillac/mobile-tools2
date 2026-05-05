require "net/http"
require "json"
require "open3"

class EasyOcrReceiptParserService
  CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
  PYTHON_SCRIPT_PATH = Rails.root.join("lib", "easy_ocr.py").to_s

  class OcrError < StandardError; end
  class RateLimitError < StandardError; end

  attr_reader :error, :receipt_total, :restaurant_name, :ocr_text

  def initialize(image_path, content_type = "image/jpeg")
    @image_path = image_path
    @content_type = content_type
    @error = nil
    @receipt_total = nil
    @restaurant_name = nil
    @ocr_text = nil
  end

  def parse
    return [] unless @image_path.present? && File.exist?(@image_path)

    # Step 1: Extract text using EasyOCR
    ocr_result = extract_text_with_easyocr
    return [] unless ocr_result[:success]

    @ocr_text = ocr_result[:full_text]
    return [] if @ocr_text.blank?

    Rails.logger.info("EasyOCR extracted #{ocr_result[:line_count]} lines of text")

    # Step 2: Parse extracted text with Claude
    response = call_claude_api(@ocr_text)
    parse_response(response)
  rescue OcrError => e
    @error = :ocr_failed
    Rails.logger.error("EasyOcrReceiptParserService OCR error: #{e.message}")
    []
  rescue RateLimitError => e
    @error = :rate_limit
    Rails.logger.error("EasyOcrReceiptParserService rate limit: #{e.message}")
    []
  rescue StandardError => e
    Rails.logger.error("EasyOcrReceiptParserService error: #{e.message}")
    []
  end

  def ocr_failed?
    @error == :ocr_failed
  end

  def rate_limited?
    @error == :rate_limit
  end

  private

  def extract_text_with_easyocr
    unless File.exist?(PYTHON_SCRIPT_PATH)
      raise OcrError, "EasyOCR script not found at #{PYTHON_SCRIPT_PATH}"
    end

    stdout, stderr, status = Open3.capture3("python3", PYTHON_SCRIPT_PATH, @image_path)

    unless status.success?
      Rails.logger.error("EasyOCR stderr: #{stderr}")
      raise OcrError, "EasyOCR failed: #{stderr}"
    end

    result = JSON.parse(stdout)

    unless result["success"]
      raise OcrError, "EasyOCR error: #{result['error']}"
    end

    result.symbolize_keys
  rescue JSON::ParserError => e
    raise OcrError, "Failed to parse EasyOCR output: #{e.message}"
  end

  def call_claude_api(ocr_text)
    uri = URI(CLAUDE_API_URL)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE # TODO: Fix SSL certs for production
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = api_key
    request["anthropic-version"] = "2023-06-01"
    request.body = request_body(ocr_text).to_json

    response = http.request(request)
    JSON.parse(response.body)
  end

  def request_body(ocr_text)
    {
      model: "claude-sonnet-4-20250514",
      max_tokens: 4096,
      temperature: 0,
      messages: [
        {
          role: "user",
          content: "#{prompt}\n\nOCR TEXT FROM RECEIPT:\n```\n#{ocr_text}\n```"
        }
      ]
    }
  end

  def prompt
    <<~PROMPT
      Parse the following OCR-extracted text from a restaurant or grocery receipt.
      The text may contain OCR errors, line breaks, and formatting issues.

      Return a JSON object with:
      - "restaurant_name": the name of the business (short, clean name - e.g., "Encanto Cafe", "Alsuper")
      - "items": array of line items
      - "receipt_total": the TOTAL amount shown on the receipt (the final amount paid)

      For each item in the "items" array:
      - "name": the item name (string)
      - "quantity": always set to 1 (prices are line totals)
      - "price": the LINE TOTAL price for that item (number)
      - "is_modifier": true if this is a modifier/add-on (like extra ingredients), false otherwise

      CRITICAL RULES FOR PRICES:
      1. The "price" field MUST be the LINE TOTAL, NOT the unit price
      2. If an item shows "2 BEBIDA 39.90" with "$79.80" at the end, use 79.80 (the line total)
      3. The line total is always the RIGHTMOST price on the line or the price in the IMPORTE column
      4. OCR often adds "8" or "$" prefix to prices - "879.80" means $79.80, "8130.00" means $130.00
      5. When you see an item name followed by a small number (like "BEBIDA 39.90"), that's the UNIT PRICE
         - Look for the LINE TOTAL which will be higher (unit price × quantity)

      OTHER RULES:
      1. Look for the business name at the top (e.g., "ENCANTO", "alsuper")
      2. Skip subtotals, tax (IVA), tips - only include actual items
      3. Look for "TOTAL" to get receipt_total - OCR may show "9676.80" which means $676.80
      4. If you see "Redondeo" (rounding), include it as an item
      5. Handle OCR errors:
         - Leading "8" or "9" before prices are OCR artifacts (839.00 = $39.00)
         - Numbers with spaces: "19 90" = 19.90
         - Prices ending in N or * are line totals

      For ALSUPER grocery receipts:
      - Skip category headers like "ABARROTE COMEST", "PERECEDEROS"
      - Use P.TOTAL column (rightmost, ends with N or *)
      - TOTAL VENTA is subtotal, TOTAL is final amount

      Return ONLY the JSON object, no other text.
    PROMPT
  end

  def parse_response(response)
    if response["error"]
      error_message = response.dig("error", "message") || ""
      error_type = response.dig("error", "type") || ""

      if error_type == "rate_limit_error" || error_message.include?("rate") || error_message.include?("quota")
        raise RateLimitError, error_message
      end

      Rails.logger.error("Claude API error: #{error_message}")
      return []
    end

    text = response.dig("content", 0, "text")
    return [] unless text

    # Extract JSON from response
    clean_text = text.dup
    if clean_text =~ /```json\s*(.*?)```/m
      clean_text = $1.strip
    elsif clean_text =~ /```\s*(.*?)```/m
      clean_text = $1.strip
    elsif clean_text =~ /(\{.*\})/m
      clean_text = $1.strip
    end

    parsed = JSON.parse(clean_text)

    if parsed.is_a?(Hash) && parsed["items"]
      @receipt_total = parsed["receipt_total"].to_f.round(2) if parsed["receipt_total"]
      @restaurant_name = parsed["restaurant_name"].to_s.strip.presence if parsed["restaurant_name"]
      items_array = parsed["items"]
    else
      items_array = parsed
    end

    items_array.map do |item|
      {
        name: (item["name"] || item["item"]).to_s,
        quantity: 1,
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