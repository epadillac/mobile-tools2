require "net/http"
require "json"
require "base64"

class ClaudeReceiptParserService
  CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
  # Base64 encoding increases size by ~33%, so 3.5MB raw becomes ~4.7MB encoded (under 5MB limit)
  # Increased to 3MB for better OCR accuracy on detailed receipts
  MAX_IMAGE_SIZE = 3.0 * 1024 * 1024
  MAX_DIMENSION = 3000 # Max width/height for resizing

  class RateLimitError < StandardError; end

  attr_reader :error, :receipt_total, :restaurant_name

  def initialize(image_path, content_type = "image/jpeg")
    @image_path = image_path
    @content_type = content_type
    @error = nil
    @receipt_total = nil
    @restaurant_name = nil
    @compressed_tempfile = nil
    @was_compressed = false
  end

  # Maximum difference to auto-correct (in currency units)
  MAX_AUTO_CORRECTION = 5.0

  def parse
    return [] unless @image_path.present? && File.exist?(@image_path)

    response = call_claude_api
    result = parse_response(response)
    is_alsuper = false

    # Check if Alsuper was detected - make a second call with specialized prompt
    if @detected_alsuper
      Rails.logger.info("Alsuper receipt detected, using specialized prompt")
      @detected_alsuper = false # Reset flag
      is_alsuper = true
      response = call_claude_api(use_alsuper_prompt: true)
      result = parse_response(response)
    end

    # Check if Chihua Restaurant was detected - make a second call with specialized prompt
    if @detected_chihua
      Rails.logger.info("Chihua Restaurant receipt detected, using specialized prompt")
      @detected_chihua = false # Reset flag
      response = call_claude_api(use_chihua_prompt: true)
      result = parse_response(response)
    end

    # Check if IL Fornaio was detected - make a second call with specialized prompt
    if @detected_ilfornaio
      Rails.logger.info("IL Fornaio receipt detected, using specialized prompt")
      @detected_ilfornaio = false # Reset flag
      response = call_claude_api(use_ilfornaio_prompt: true)
      result = parse_response(response)
    end

    # Check if Churreria Porfirio was detected - make a second call with specialized prompt
    if @detected_porfirio
      Rails.logger.info("Churreria Porfirio receipt detected, using specialized prompt")
      @detected_porfirio = false # Reset flag
      response = call_claude_api(use_porfirio_prompt: true)
      result = parse_response(response)
    end

    # Check if La Cabaña Smokehouse was detected - make a second call with specialized prompt
    if @detected_lacabana
      Rails.logger.info("La Cabaña Smokehouse receipt detected, using specialized prompt")
      @detected_lacabana = false # Reset flag
      response = call_claude_api(use_lacabana_prompt: true)
      result = parse_response(response)
      # Distribute IVA in Ruby (more reliable than asking Claude to do math)
      result = distribute_iva(result)
    end

    # Auto-correct small differences between items sum and receipt total (Alsuper only)
    result = apply_correction(result) if is_alsuper && @receipt_total && result.any?

    result
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

  def call_claude_api(use_alsuper_prompt: false, use_chihua_prompt: false, use_ilfornaio_prompt: false, use_porfirio_prompt: false, use_lacabana_prompt: false)
    uri = URI(CLAUDE_API_URL)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE # TODO: Fix SSL certs for production
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = api_key
    request["anthropic-version"] = "2023-06-01"
    request.body = request_body(use_alsuper_prompt: use_alsuper_prompt, use_chihua_prompt: use_chihua_prompt, use_ilfornaio_prompt: use_ilfornaio_prompt, use_porfirio_prompt: use_porfirio_prompt, use_lacabana_prompt: use_lacabana_prompt).to_json

    response = http.request(request)
    JSON.parse(response.body)
  end

  def request_body(use_alsuper_prompt: false, use_chihua_prompt: false, use_ilfornaio_prompt: false, use_porfirio_prompt: false, use_lacabana_prompt: false)
    selected_prompt = if use_lacabana_prompt
      lacabana_prompt
    elsif use_porfirio_prompt
      porfirio_prompt
    elsif use_ilfornaio_prompt
      ilfornaio_prompt
    elsif use_chihua_prompt
      chihua_prompt
    elsif use_alsuper_prompt
      alsuper_prompt
    else
      prompt
    end

    # Encode image first to determine if compression happened (affects media_type)
    image_data = encoded_image
    image_media_type = media_type

    {
      model: "claude-sonnet-4-20250514",
      max_tokens: 4096,
      temperature: 0,  # More deterministic results for better accuracy
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              source: {
                type: "base64",
                media_type: image_media_type,
                data: image_data
              }
            },
            {
              type: "text",
              text: selected_prompt
            }
          ]
        }
      ]
    }
  end

  def media_type
    # If image was compressed, it's now JPEG regardless of original format
    return "image/jpeg" if @was_compressed

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
      First, look at the TOP of this receipt to identify the business.
      If you see "alsuper" (grocery store logo), respond with EXACTLY: {"business_type": "alsuper"}
      If you see "chihua restaurant" or "tacosy cortes chihua", respond with EXACTLY: {"business_type": "chihua"}
      If you see "il fornaio" or "IL Fornaio", respond with EXACTLY: {"business_type": "ilfornaio"}
      If you see "churreria porfirio" or "CHURRERIA PORFIRIO", respond with EXACTLY: {"business_type": "porfirio"}
      If you see "la cabaña" or "smokehouse" or "LA CABAÑA SMOKEHOUSE", respond with EXACTLY: {"business_type": "lacabana"}
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
      1. The "price" field should be the EXACT price shown on that line of the receipt. Do NOT calculate, adjust, or redistribute any tax/IVA.
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
      7. For "receipt_total", look for the final TOTAL line on the receipt (may be labeled "TOTAL:", "Total", "Neto", "G. TOTAL", etc.)
         - Use the HIGHEST total that represents the full amount paid (including tax/IVA).
      8. IMPORTANT: Include ALL items with prices, even if the same item name appears multiple times on the receipt.
         - For example, if "LECHE COCO $10.00" appears twice on the receipt (once under LATTE, once under BEBIDA), include BOTH entries.
         - Each line with a price should be a separate entry in the items array.
      9. TAX/IVA HANDLING: Use the prices EXACTLY as printed on each item line. Do NOT distribute, add, or adjust for IVA/tax.
         - If the receipt shows Subtotal + IVA + Total, IGNORE the Subtotal and IVA lines — just use per-item prices as printed.
         - The item prices on most Mexican receipts already include IVA (they sum to the Total, not the Subtotal).
         - NEVER recalculate item prices using tax ratios.

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

  def alsuper_prompt
    <<~PROMPT
      Extract product items from this Alsuper grocery receipt.

      RECEIPT LAYOUT:
      ```
      CANT DESCRIP        MARCA    P.UNIT   P.TOTAL
      ABARROTE COMEST                              <- CATEGORY HEADER (skip!)
      1 PASTA PARA BARIL           19.90    19.90N <- Product line
      1 PASTA PARA BARIL           59.90    59.90N <- Product line
      ABARROTE NOM                                 <- CATEGORY HEADER (skip!)
      2 PAPEL ALUM MIMAR           19.90    39.80* <- Product line
      PERECEDEROS                                  <- CATEGORY HEADER (skip!)
      1 CREMA ACID  LALA           41.90    41.90* <- Product line
      ----------------------------------------
      TOTAL VENTA ------> 1661.53
      REDONDEO                      0.47           <- Include this!
      TOTAL --------->   1662.00
      ```

      CRITICAL: Category headers like "ABARROTE COMEST", "ABARROTE NOM", "PERECEDEROS"
      appear ALONE on a line with NO PRICES. These are NOT products - SKIP THEM!

      Product lines ALWAYS have:
      - A number at the start (quantity)
      - A price ending in N or * at the far right (P.TOTAL)

      Extract ONLY product lines. Use the P.TOTAL (rightmost price with N or *).

      ALSO include REDONDEO (rounding) as the LAST item if present.

      VALIDATION: Your item prices + REDONDEO must sum to TOTAL (the final total paid).

      Return JSON:
      {
        "restaurant_name": "Alsuper",
        "receipt_total": [TOTAL - the final total paid, e.g. 1662.00],
        "items": [
          {"name": "[product]", "quantity": 1, "price": [P.TOTAL number], "is_modifier": false},
          {"name": "Redondeo", "quantity": 1, "price": [REDONDEO amount], "is_modifier": false}
        ]
      }
    PROMPT
  end

  def chihua_prompt
    <<~PROMPT
      Extract items from this Chihua Restaurant receipt.

      RECEIPT LAYOUT:
      ```
      CHIHUA RESTAURANT
      TACOSY CORTES CHIHUA S.A. DE C.V.
      ...
      SUCURSAL CAFETALES
      MESA 10B
      FOLIO 54568     30/01/2026 10:34 a.m.
      cajero:Valeria                  Caja 1
      mesero:Valeria                  Per:1
      ======================================
      Cant Descripcion              Importe
      ======================================
      5    buffet @$240.52       $1,202.59
      1    buffet nito @$102.59    $102.59
      5    cafe combo @$0.00
      1    leche con chocolate @$30.17 $30.17
      1    refresco @$30.17          $30.17
      --------------------------------------
      Servicio de comedor   13 articulos
                  subtotal: $1,365.52
                      IVA:   $218.48
                Total $1,584.00
      ```

      FORMAT RULES:
      - Each line shows: quantity, item name, unit price with @$, and LINE TOTAL (Importe)
      - Lines with quantity > 1 show the multiplied total in Importe (e.g., 5 x $240.52 = $1,202.59)
      - Items with @$0.00 or no Importe value (like complimentary cafe combo) should be included with price 0.00
      - Always set quantity to 1 since we use line totals

      CRITICAL - IVA TAX DISTRIBUTION:
      This receipt shows a subtotal and an IVA (tax) line before the final total.
      You MUST distribute the IVA proportionally across ALL items so that the sum of item prices equals the TOTAL (not the subtotal).
      Formula: each item's final price = item_line_total x (receipt_total / subtotal), rounded to 2 decimals.
      Ensure the item prices sum to EXACTLY the receipt total. Adjust rounding on the largest item if needed.

      Example: if subtotal=$1,365.52, IVA=$218.48, total=$1,584.00:
        ratio = 1584.00 / 1365.52 = 1.15993...
        Buffet line total $1,202.59 -> $1,202.59 x 1.15993 = $1,394.96
        Buffet Nito line total $102.59 -> $102.59 x 1.15993 = $119.00
        etc.

      SKIP these lines:
      - Subtotal, IVA, Total, cambio, DOLARES
      - Restaurant header info (cajero, mesero, folio, mesa, sucursal)
      - "Servicio de comedor", article count

      For "receipt_total", use the TOTAL line (final amount including IVA).

      Return JSON:
      {
        "restaurant_name": "Chihua Restaurant",
        "receipt_total": [TOTAL amount including IVA],
        "items": [
          {"name": "[item name, title case]", "quantity": 1, "price": [line total WITH IVA distributed], "is_modifier": false}
        ]
      }

      VALIDATION: The sum of all item prices MUST equal receipt_total exactly.

      Return ONLY the JSON object, no other text.
    PROMPT
  end

  def porfirio_prompt
    <<~PROMPT
      Extract items from this Churreria Porfirio receipt.

      RECEIPT LAYOUT:
      ```
      CHURRERIA PORFIRIO
      Plaza Mallo
      ...
      # TICKET 6099972
      FECHA : 2026-01-31          HORA : 20:43:47
      Cant  Descripción     Precio    Importe
      1     Cafe            0.00      87.00
            Café de olla    75.00
            473ml
            Leche           12.00
            Deslactosada
      1     Rellenos        0.00      99.00
            3 Pzas.         99.00
            • cajeta qc choko
      Subtotal              160.34
      Impuestos (16%)        25.66
      Total (MXN)           186.00
      ```

      FORMAT RULES:
      - Main lines show: Cant, category name (e.g., "Cafe", "Rellenos"), Precio 0.00, and Importe (line total)
      - Sub-lines below the main line show the ACTUAL items and their individual prices
      - The Importe on the main line is the SUM of the sub-item prices (e.g., Cafe $87 = Café de olla $75 + Leche Deslactosada $12)
      - DO NOT use the main line Importe as a single item. Instead, extract the SUB-ITEMS with their individual prices.
      - Lines that are just descriptions/sizes (e.g., "473ml") or flavor notes (e.g., "• cajeta qc choko") with NO price should be treated as modifiers with price 0.
      - Always set quantity to 1 since we use line totals.

      CRITICAL - IVA IS ALREADY INCLUDED IN ITEM PRICES:
      - The sub-item prices already include tax (they sum to Total, not Subtotal)
      - DO NOT add or distribute Impuestos/IVA on top of item prices
      - The sum of all extracted sub-item prices must equal the Total (MXN) amount

      SKIP these lines:
      - The main category lines (Cafe 0.00 87.00, Rellenos 0.00 99.00) — use sub-items instead
      - Subtotal, Impuestos, Total, Importe Recibido, Cambio
      - Payment info (Efectivo, TD, TC)
      - Restaurant header info, ticket number, date, footer text

      For "receipt_total", use the Total (MXN) line.

      Return JSON:
      {
        "restaurant_name": "Churreria Porfirio",
        "receipt_total": [Total MXN amount],
        "items": [
          {"name": "[sub-item name, title case]", "quantity": 1, "price": [sub-item price], "is_modifier": false},
          {"name": "[modifier/add-on name]", "quantity": 1, "price": [price or 0], "is_modifier": true}
        ]
      }

      Mark as is_modifier=true:
      - Add-ons like "Leche Deslactosada" (milk type additions to a drink)
      - Size descriptors with no price (e.g., "473ml")
      - Flavor notes (e.g., "cajeta qc choko")

      VALIDATION: The sum of all item prices MUST equal receipt_total exactly.

      Return ONLY the JSON object, no other text.
    PROMPT
  end

  def ilfornaio_prompt
    <<~PROMPT
      Extract items from this IL Fornaio restaurant receipt.

      RECEIPT LAYOUT:
      ```
      Cuenta solicitada
      IL Fornaio (Chih)
      Area de servicio    Comedor 2
      Mesa                8
      # orden             250126-P-0040
      Fecha               25/01/26 16:43:51
      Comensales          3
      Atendió             Karime R
      Tipo                Comedor
      ----------------------------------
      1 Capricciosa               $200.00
      1 Pizza Peperoni             $210.00
      1 Arlecchino                 $240.00
      1 Tarro Chelado              $16.00
      3 Café Americano             $120.00
      1 Filetto Alla Panceta       $360.00
      1 Cerveza Premium            $52.00
      1 Refresco                   $45.00
      1 Refresco                   $45.00
      ----------------------------------
      Importe                    $1,288.00
      Descuento                     -$0.00
      Cargos por servicio           +$0.00
      Subtotal                   $1,110.34
      IVA                          $177.66
      Total                      $1,288.00
      ```

      FORMAT RULES:
      - Each line shows: quantity, item name, and LINE TOTAL price
      - Lines with quantity > 1 already show the multiplied total (e.g., 3 Café Americano $120.00 means $120 total for all 3)
      - Always set quantity to 1 since we use line totals

      CRITICAL - IVA IS ALREADY INCLUDED IN ITEM PRICES:
      - The "Importe" line is the sum of all item prices and it equals the "Total"
      - The "Subtotal" shown is the pre-tax breakdown, but item prices ALREADY INCLUDE TAX
      - DO NOT add IVA on top of item prices. DO NOT distribute IVA. Use prices AS-IS from the receipt.
      - The sum of all item prices must equal the Total/Importe amount.

      SKIP these lines:
      - Importe, Descuento, Cargos por servicio, Subtotal, IVA, Total
      - Restaurant header info (Area de servicio, Mesa, orden, Fecha, Comensales, Atendió, Tipo)
      - "Gracias por tu compra", facturación info, QR codes

      For "receipt_total", use the TOTAL line (final amount).

      Return JSON:
      {
        "restaurant_name": "Il Fornaio",
        "receipt_total": [TOTAL amount],
        "items": [
          {"name": "[item name, title case]", "quantity": 1, "price": [line total AS SHOWN on receipt], "is_modifier": false}
        ]
      }

      VALIDATION: The sum of all item prices MUST equal receipt_total exactly.

      Return ONLY the JSON object, no other text.
    PROMPT
  end

  def lacabana_prompt
    <<~PROMPT
      Extract items from this La Cabaña Smokehouse receipt.

      RECEIPT STRUCTURE - READ CAREFULLY:
      The receipt has columns: CANT | DESCRIPCION | % DESC | PRECIO
      The PRECIO column is at the FAR RIGHT edge of the receipt.

      CRITICAL PRICE READING RULES:
      1. The PRECIO (price) is the RIGHTMOST number on each line
      2. DO NOT confuse quantities or percentages with prices
      3. Prices are typically $24, $35, $49, $69, $90, $118, $140, $159, $169, $240, $639, $779, $837, $898, etc.
      4. If you see a small number (like 1, 2, 3, 4, 6) at the LEFT of a line, that's the QUANTITY, not the price

      EXAMPLE LINE READING:
      "2    BOHEMIA OBSCURA              $118.00"
      - CANT (quantity): 2
      - DESCRIPCION: BOHEMIA OBSCURA
      - PRECIO: $118.00 (this is the LINE TOTAL for 2 beers)

      "3    BRISKET SH                   $837.00"
      - CANT: 3
      - DESCRIPCION: BRISKET SH
      - PRECIO: $837.00 (line total for 3 briskets)

      "1    RACK Y MEDIO DE CERD         $639.00"
      - CANT: 1
      - DESCRIPCION: RACK Y MEDIO DE CERD
      - PRECIO: $639.00

      "2    RACK DE CERDO                $898.00"
      - CANT: 2
      - DESCRIPCION: RACK DE CERDO
      - PRECIO: $898.00 (line total for 2 racks)

      ITEMS WITH $0.00:
      - Items with "100%" in the discount column have price $0.00
      - Sub-items without their own price (ENSALADA DE COL, 2 PZ ELOTE, PAPAS 200 G) = $0.00

      SUB-ITEMS:
      Lines that start with spaces (indented) and have no CANT number are sub-items:
      "     CARTA BLANCA (P/CUB) (6.0 X) $240.00" - sub-item under CUBETA CERVEZA

      DO NOT CALCULATE IVA - return prices exactly as printed on receipt.

      SKIP: Subtotal, IVA, Total lines, headers, footers.

      Return JSON:
      {
        "restaurant_name": "La Cabaña Smokehouse",
        "receipt_total": [Total from receipt including IVA, ~$4932],
        "items": [
          {"name": "ITEM NAME", "quantity": 1, "price": [PRE-TAX price as printed], "is_modifier": false}
        ]
      }

      Mark is_modifier=true for indented sub-items only.
      Items should sum to approximately $4,251 (the subtotal), NOT to receipt_total.

      Return ONLY valid JSON, no other text.
    PROMPT
  end

  # Distribute IVA proportionally across items so they sum to receipt_total
  def distribute_iva(items)
    return items if items.empty? || @receipt_total.nil?

    items_sum = items.sum { |item| item[:price] }
    return items if items_sum <= 0

    # Calculate ratio to distribute IVA
    ratio = @receipt_total / items_sum
    Rails.logger.info("Distributing IVA: items_sum=#{items_sum}, receipt_total=#{@receipt_total}, ratio=#{ratio.round(4)}")

    # Only distribute if ratio is reasonable (between 1.0 and 1.25 for Mexican IVA)
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
    @was_compressed = true  # Mark that we compressed to JPEG

    # Start with resize and high quality for better OCR
    quality = 85
    result_path = nil

    loop do
      pipeline = ImageProcessing::MiniMagick
        .source(@image_path)
        .resize_to_limit(MAX_DIMENSION, MAX_DIMENSION)
        .saver(quality: quality)
        .call(destination: @compressed_tempfile.path)

      result_size = File.size(@compressed_tempfile.path)
      Rails.logger.info("Compressed to #{(result_size / 1024.0 / 1024.0).round(2)}MB at quality #{quality}")

      if result_size <= MAX_IMAGE_SIZE || quality <= 50
        result_path = @compressed_tempfile.path
        break
      end

      # Reduce quality and try again
      quality -= 10
    end

    result_path
  end

  def parse_response(response)
    if response["error"]
      error_message = response.dig("error", "message") || ""
      error_type = response.dig("error", "type") || ""

      # Check for rate limit or billing/credit errors - fall back to Gemini
      if error_type == "rate_limit_error" ||
         error_message.include?("rate") ||
         error_message.include?("quota") ||
         error_message.include?("credit balance") ||
         error_message.include?("billing") ||
         error_type == "invalid_request_error"
        raise RateLimitError, error_message
      end

      Rails.logger.error("Claude API error: #{error_message}")
      return []
    end

    text = response.dig("content", 0, "text")
    return [] unless text

    # Extract JSON from response - handle code blocks and text before/after JSON
    clean_text = text.dup

    # If there's a code block, extract just the JSON from it
    if clean_text =~ /```json\s*(.*?)```/m
      clean_text = $1.strip
    elsif clean_text =~ /```\s*(.*?)```/m
      clean_text = $1.strip
    elsif clean_text =~ /(\{.*\})/m
      # Extract just the JSON object if there's text around it
      clean_text = $1.strip
    end

    parsed = JSON.parse(clean_text)

    # Check if this is a business detection response
    if parsed.is_a?(Hash) && parsed["business_type"]
      case parsed["business_type"]
      when "alsuper"
        @detected_alsuper = true
      when "chihua"
        @detected_chihua = true
      when "ilfornaio"
        @detected_ilfornaio = true
      when "porfirio"
        @detected_porfirio = true
      when "lacabana"
        @detected_lacabana = true
      end
      return [] if @detected_alsuper || @detected_chihua || @detected_ilfornaio || @detected_porfirio || @detected_lacabana
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
    Rails.logger.error("Failed to parse Claude response: #{e.message}, text: #{text}")
    []
  end

  def api_key
    ENV["ANTHROPIC_API_KEY"] || Rails.application.credentials.dig(:anthropic, :api_key)
  end

  # Add an adjustment item if there's a small difference between items sum and receipt total
  def apply_correction(items)
    return items if items.empty? || @receipt_total.nil?

    items_sum = items.sum { |item| item[:price] }
    difference = (@receipt_total - items_sum).round(2)

    # No correction needed if difference is negligible (less than 1 cent)
    return items if difference.abs < 0.01

    # Only auto-correct small differences (likely OCR errors)
    if difference.abs <= MAX_AUTO_CORRECTION
      Rails.logger.info("Auto-correcting difference of $#{difference} between items ($#{items_sum}) and receipt total ($#{@receipt_total})")

      items << {
        name: "Ajuste",
        quantity: 1,
        price: difference,
        is_modifier: false
      }
    else
      Rails.logger.warn("Large difference of $#{difference} between items ($#{items_sum}) and receipt total ($#{@receipt_total}) - not auto-correcting")
    end

    items
  end
end