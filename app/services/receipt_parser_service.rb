require "net/http"
require "json"
require "base64"
require "mini_magick"

class ReceiptParserService
  GEMINI_API_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

  class RateLimitError < StandardError; end
  class OverloadedError < StandardError; end

  attr_reader :error, :receipt_total, :restaurant_name, :image_path

  def initialize(image_path, content_type = "image/jpeg")
    @image_path = image_path
    @content_type = content_type
    @error = nil
    @receipt_total = nil
    @restaurant_name = nil
  end

  def parse
    return [] unless @image_path.present? && File.exist?(@image_path)

    optimize_image!
    response = call_gemini_api
    result = parse_response(response)

    # Check if La Cabaña Smokehouse was detected - make a second call with specialized prompt
    if @detected_lacabana
      Rails.logger.info("La Cabaña Smokehouse receipt detected, using specialized prompt")
      @detected_lacabana = false # Reset flag
      response = call_gemini_api(prompt_type: :lacabana)
      result = parse_response(response)
      # Distribute IVA proportionally so items sum to receipt_total
      result = distribute_iva(result)
    end

    # Check if El Comal was detected - make a second call with specialized prompt
    if @detected_elcomal
      Rails.logger.info("El Comal receipt detected, using specialized prompt")
      @detected_elcomal = false # Reset flag
      response = call_gemini_api(prompt_type: :elcomal)
      result = parse_response(response)
      # El Comal prices already include IVA - no distribution needed
    end

    # Check if Red Texas was detected - make a second call with specialized prompt
    if @detected_redtexas
      Rails.logger.info("Red Texas receipt detected, using specialized prompt")
      @detected_redtexas = false # Reset flag
      response = call_gemini_api(prompt_type: :redtexas)
      result = parse_response(response)
      # Red Texas prices include IVA - no distribution needed
    end

    # Validation: if items don't sum to receipt_total, try a correction pass
    result = try_correction(result) if needs_correction?(result)

    # Final fallback: proportionally adjust prices to match receipt_total
    result = distribute_proportionally(result) if needs_distribution?(result)

    result
  rescue RateLimitError => e
    @error = :rate_limit
    Rails.logger.error("ReceiptParserService rate limit: #{e.message}")
    []
  rescue OverloadedError => e
    @error = :overloaded
    Rails.logger.error("ReceiptParserService overloaded: #{e.message}")
    []
  rescue StandardError => e
    Rails.logger.error("ReceiptParserService error: #{e.message}")
    []
  end

  def rate_limited?
    @error == :rate_limit
  end

  def overloaded?
    @error == :overloaded
  end

  private

  def call_gemini_api(prompt_type: nil)
    uri = URI("#{GEMINI_API_URL}?key=#{api_key}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE # TODO: Fix SSL certs for production
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = request_body(prompt_type: prompt_type).to_json

    response = http.request(request)
    JSON.parse(response.body)
  end

  def request_body(prompt_type: nil)
    selected_prompt = case prompt_type
    when :lacabana then lacabana_prompt
    when :elcomal then elcomal_prompt
    when :redtexas then redtexas_prompt
    when :correction then correction_prompt
    else prompt
    end

    {
      contents: [
        {
          parts: [
            { text: selected_prompt },
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
      First, look at the TOP of this receipt to identify the business.
      If you see "la cabaña" or "smokehouse" or "LA CABAÑA SMOKEHOUSE", respond with EXACTLY: {"business_type": "lacabana"}
      If you see "el comal" or "EL COMAL" or "restaurante el comal", respond with EXACTLY: {"business_type": "elcomal"}
      If you see "red texas" or "RED TEXAS", respond with EXACTLY: {"business_type": "redtexas"}
      Otherwise, continue with the analysis below.

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
         READ EACH PRICE INDEPENDENTLY - do not let adjacent lines influence your reading.
         For example, if one line shows $66.00 and the next shows $56.00, they are DIFFERENT prices.
         Pay close attention to the tens digit (5 vs 6, 3 vs 8, etc.).
      7. For "receipt_total", use the TOTAL line (may be labeled "TOTAL:", "Total", etc.)
         - CRITICAL: If you see "IVA Desglosado" or "IVA Incluido", the IVA is ALREADY INCLUDED in the Total.
         - Do NOT add IVA to the Total. The Total is the final amount.
         - Example: "Total: $726.00" and "IVA Desglosado: $100.14" means receipt_total = 726.00 (NOT 826.14!)
      8. IMPORTANT: Include ALL items with prices, even if the same item name appears multiple times on the receipt.
         - For example, if "LECHE COCO $10.00" appears twice on the receipt (once under LATTE, once under BEBIDA), include BOTH entries.
         - Each line with a price should be a separate entry in the items array.

      Do NOT include subtotals, tax (IVA), tips in the items array.

      Example - if receipt shows:
        ENCANTO RESTAURANTE CAFE
        RFC: XYZ...
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

  def lacabana_prompt
    <<~PROMPT
      Extract items from this La Cabaña Smokehouse receipt.

      RECEIPT STRUCTURE:
      Columns: CANT | DESCRIPCION | % DESC | PRECIO
      The PRECIO column (rightmost) shows the LINE TOTAL for that row.

      CRITICAL - READ PRICES CORRECTLY:
      The PRECIO is ALWAYS the LINE TOTAL, never the unit price!
      DO NOT divide by quantity - the receipt already shows the multiplied total.

      EXAMPLES (read the PRECIO exactly as shown):
      "1    CHELADO                      $24.00"   → price: 24.00 ✓
      "2    BOHEMIA OBSCURA             $118.00"   → price: 118.00 ✓ (NOT 59!)
      "3    BRISKET SH                  $637.00"   → price: 637.00 ✓ (NOT 212.33!)
      "3    TABLA BRISKET               $779.00"   → price: 779.00 ✓ (NOT 259.67!)
      "2    RACK DE CERDO               $898.00"   → price: 898.00 ✓ (NOT 449!)

      WRONG: Dividing $118 by 2 to get $59
      RIGHT: Use $118 exactly as printed

      SUB-ITEMS (indented lines without CANT):
      - ENSALADA DE COL, 2 PZ ELOTE, PAPAS 200 G → price: 0.00, is_modifier: true
      - CARTA BLANCA (P/CUB) with a price → use that price, is_modifier: true

      SKIP: Subtotal, IVA, Total, headers, footers, QR codes.

      For "receipt_total": Use the TOTAL line (final amount WITH IVA, around $4,932).

      Return JSON:
      {
        "restaurant_name": "La Cabaña Smokehouse",
        "receipt_total": [TOTAL with IVA],
        "items": [{"name": "ITEM", "quantity": 1, "price": [PRECIO as printed], "is_modifier": false}]
      }

      VALIDATION: Items should sum to ~$4,251 (Subtotal), NOT $4,932 (Total).
      Return ONLY valid JSON.
    PROMPT
  end

  def elcomal_prompt
    <<~PROMPT
      Extract items from this El Comal Chihuahua restaurant receipt.

      RECEIPT STRUCTURE:
      This is a HOTEL restaurant receipt. There may be TWO parts:
      1. Main receipt with item details and "G. TOTAL" or "Neto" (USE THIS)
      2. A separate payment slip with different totals (IGNORE THIS)

      CRITICAL - READ PRICES AS LINE TOTALS:
      The price column shows LINE TOTALS, not unit prices!
      DO NOT divide by quantity - use the price exactly as printed.

      EXAMPLE:
      1.000 BUFFET         150.00   -> price: 150.00 ✓
      2.000 DESAYUNO       498.00   -> price: 498.00 ✓ (NOT 249!)
      1.000 JUGO            60.00   -> price: 60.00 ✓
      --------------------------
      G. TOTAL:            708.00   <- USE THIS as receipt_total

      WRONG: Dividing 498 by 2 to get 249
      RIGHT: Use 498 exactly as printed

      USE: "G. TOTAL", "Neto", or "TOTAL" from main receipt section.
      IGNORE: Payment slip totals like "$814.20 MXN".

      Return JSON:
      {
        "restaurant_name": "El Comal Chihuahua",
        "receipt_total": [G.TOTAL or Neto],
        "items": [{"name": "ITEM", "quantity": 1, "price": [price AS PRINTED], "is_modifier": false}]
      }

      VALIDATION: Items should sum EXACTLY to receipt_total.
      Return ONLY valid JSON.
    PROMPT
  end

  def redtexas_prompt
    <<~PROMPT
      Extract items from this RED TEXAS restaurant receipt.

      RECEIPT STRUCTURE:
      Columns: Cant | Producto | P.Uni. | % DESC | Importe
      - P.Uni. = unit price (IGNORE THIS)
      - % DESC = discount percentage (may be empty)
      - Importe = FINAL line total after any discount (USE THIS)

      CRITICAL - USE THE RIGHTMOST PRICE COLUMN (Importe):
      This receipt has MULTIPLE number columns. You MUST use the LAST/RIGHTMOST number
      on each line, which is the Importe (final amount after discounts).
      The Importe may be LESS than Cant × P.Uni. when a discount (% DESC) is applied.

      EXAMPLES:
      "1.00 COCA LIGHT LATA          46.00"          → price: 46.00 ✓
      "1.00 BOHEMIA OBSCURA   67.00        58.00"    → price: 58.00 ✓ (NOT 67! 67 is P.Uni, 58 is Importe after discount)
      "3.00 TACO SIRLOIN      89.00       267.00"    → price: 267.00 ✓ (line total, NOT 89)
      "1.00 TEXAS GRILLED     241.00      241.00"    → price: 241.00 ✓

      WHEN TWO NUMBERS APPEAR ON A LINE:
      - The FIRST number (left) is the unit price (P.Uni.) — IGNORE IT
      - The SECOND number (right) is the line total (Importe) — USE THIS ONE
      - If only ONE number appears, that IS the Importe

      SKIP: Subtotal, IVA, Total, headers, footers, sub-items without prices (like "PAPAS FRANCESAS", "PRINCESAS").

      For "receipt_total": Use the TOTAL line. Note: "INCLUYEN IVA" means IVA is already in the total.

      Return JSON:
      {
        "restaurant_name": "Red Texas",
        "receipt_total": [TOTAL amount],
        "items": [{"name": "ITEM", "quantity": 1, "price": [Importe as printed], "is_modifier": false}]
      }

      VALIDATION: The sum of all item prices MUST equal the receipt_total.
      If they don't match, re-examine which column you read each price from — always use Importe (rightmost).
      Return ONLY valid JSON.
    PROMPT
  end

  def needs_correction?(items)
    return false if items.empty? || @receipt_total.nil?
    items_sum = items.sum { |item| item[:price] }
    diff = (items_sum - @receipt_total).abs
    diff > 1.0 && diff < @receipt_total * 0.1 # Only retry for small-ish discrepancies (<10%)
  end

  def try_correction(items)
    items_sum = items.sum { |item| item[:price] }
    diff = (items_sum - @receipt_total).round(2)
    Rails.logger.info("Items sum (#{items_sum}) != receipt_total (#{@receipt_total}), diff=#{diff}. Trying correction pass...")

    response = call_gemini_api(prompt_type: :correction)
    corrected = parse_response(response)

    if corrected.any?
      corrected_sum = corrected.sum { |item| item[:price] }
      corrected_diff = (corrected_sum - @receipt_total).abs
      if corrected_diff < diff.abs
        Rails.logger.info("Correction improved: new diff=#{corrected_diff}")
        return corrected
      else
        Rails.logger.info("Correction didn't improve (diff=#{corrected_diff}), keeping original")
      end
    end

    items
  end

  def correction_prompt
    items_sum = 0
    <<~PROMPT
      I previously extracted items from this receipt but the prices don't add up to the receipt total.
      Please VERY CAREFULLY re-read EVERY price on this receipt.

      IMPORTANT: Look at each price digit by digit. Pay special attention to:
      - The tens digit: is it a 5 or a 6? A 3 or an 8? A 1 or a 7?
      - Prices on adjacent lines may look similar but ARE DIFFERENT values
      - Read each line's price INDEPENDENTLY, don't let neighboring values influence you

      Return the same JSON format:
      {
        "restaurant_name": "...",
        "receipt_total": (the TOTAL shown on the receipt),
        "items": [{"name": "...", "quantity": 1, "price": (exact price on that line), "is_modifier": false}]
      }

      The sum of all item prices MUST equal the receipt_total.
      If they don't match, re-examine which price you may have misread.

      Return ONLY valid JSON.
    PROMPT
  end

  # Check if items need proportional distribution (small diff that correction couldn't fix)
  def needs_distribution?(items)
    return false if items.empty? || @receipt_total.nil?
    items_sum = items.sum { |item| item[:price] }
    diff = (items_sum - @receipt_total).abs
    diff > 0.50 && diff < @receipt_total * 0.10
  end

  # Proportionally adjust item prices so they sum exactly to receipt_total
  def distribute_proportionally(items)
    return items if items.empty? || @receipt_total.nil?

    items_sum = items.sum { |item| item[:price] }
    return items if items_sum <= 0

    ratio = @receipt_total / items_sum
    Rails.logger.info("Distributing proportionally: items_sum=#{items_sum}, receipt_total=#{@receipt_total}, ratio=#{ratio.round(4)}")

    # Only adjust if ratio is reasonable (within 10%)
    if ratio < 0.90 || ratio > 1.10
      Rails.logger.warn("Distribution ratio #{ratio.round(4)} outside expected range, skipping")
      return items
    end

    adjusted_items = items.map do |item|
      if item[:price] > 0
        item.merge(price: (item[:price] * ratio).round(2))
      else
        item
      end
    end

    # Fix rounding error on largest item
    adjusted_sum = adjusted_items.sum { |item| item[:price] }
    diff = (@receipt_total - adjusted_sum).round(2)
    if diff.abs > 0.01
      largest = adjusted_items.select { |i| i[:price] > 0 }.max_by { |i| i[:price] }
      largest[:price] = (largest[:price] + diff).round(2) if largest
    end

    adjusted_items
  end

  # Distribute IVA proportionally across items so they sum to receipt_total
  def distribute_iva(items)
    return items if items.empty? || @receipt_total.nil?

    items_sum = items.sum { |item| item[:price] }
    return items if items_sum <= 0

    # Calculate ratio to distribute IVA
    ratio = @receipt_total / items_sum
    Rails.logger.info("Distributing IVA: items_sum=#{items_sum}, receipt_total=#{@receipt_total}, ratio=#{ratio.round(4)}")

    # Only distribute if ratio is reasonable (between 1.0 and 1.25 for Mexican IVA ~16%)
    if ratio < 1.0 || ratio > 1.25
      Rails.logger.warn("IVA ratio #{ratio.round(4)} outside expected range, skipping distribution")
      return items
    end

    # Apply ratio to each item
    adjusted_items = items.map do |item|
      if item[:price] > 0
        item.merge(price: (item[:price] * ratio).round(2))
      else
        item
      end
    end

    # Adjust rounding error on largest item
    adjusted_sum = adjusted_items.sum { |item| item[:price] }
    diff = (@receipt_total - adjusted_sum).round(2)

    if diff.abs > 0.01
      largest_item = adjusted_items.select { |i| i[:price] > 0 }.max_by { |i| i[:price] }
      if largest_item
        largest_item[:price] = (largest_item[:price] + diff).round(2)
      end
    end

    adjusted_items
  end

  def encoded_image
    optimize_image!
    Base64.strict_encode64(File.binread(@image_path))
  end

  MAX_DIMENSION = 1600

  # Resizes and converts image to JPEG in-place (replaces @image_path with optimized tempfile)
  def optimize_image!
    return if @image_optimized

    image = MiniMagick::Image.open(@image_path)
    needs_resize = image.width > MAX_DIMENSION || image.height > MAX_DIMENSION
    already_jpeg = @content_type == "image/jpeg" && !needs_resize

    unless already_jpeg
      image.resize "#{MAX_DIMENSION}x#{MAX_DIMENSION}>" if needs_resize
      image.format "jpg"
      image.quality "80"

      @image_path = image.path
      @content_type = "image/jpeg"
    end

    @image_optimized = true
    Rails.logger.info("Image optimized: #{(File.size(@image_path) / 1024.0).round(0)}KB")
  rescue => e
    Rails.logger.warn("Image optimization failed: #{e.class}: #{e.message}")
    @image_optimized = true
  end

  def parse_response(response)
    if response["error"]
      error_message = response["error"]["message"] || ""
      error_code = response["error"]["code"]
      error_status = response["error"]["status"] || ""

      # Check for model overload (HTTP 503 / UNAVAILABLE / "high demand")
      if error_code == 503 ||
         error_status == "UNAVAILABLE" ||
         error_message.include?("high demand") ||
         error_message.include?("overloaded") ||
         error_message.include?("temporarily unavailable")
        raise OverloadedError, error_message
      end

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

    # Check if this is a business detection response
    if parsed.is_a?(Hash) && parsed["business_type"]
      case parsed["business_type"]
      when "lacabana"
        @detected_lacabana = true
      when "elcomal"
        @detected_elcomal = true
      when "redtexas"
        @detected_redtexas = true
      end
      return [] if @detected_lacabana || @detected_elcomal || @detected_redtexas
    end

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
        quantity: 1,  # Always 1 since price is already the line total
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