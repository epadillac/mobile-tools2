require "net/http"
require "json"
require "base64"

class InvoiceUrlParserService
  GEMINI_API_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

  class RateLimitError < StandardError; end

  attr_reader :error

  def initialize(image_path, content_type = "image/jpeg")
    @image_path = image_path
    @content_type = content_type
    @error = nil
  end

  def parse
    return empty_result unless @image_path.present? && File.exist?(@image_path)

    response = call_gemini_api
    result = parse_response(response)

    # Normalize the invoice URL
    if result[:invoice_url].present?
      url = result[:invoice_url].strip
      url = "https://#{url}" unless url.start_with?("http://", "https://")
      result[:invoice_url] = url
    end

    # Detect platform from URL
    result[:platform] = detect_platform(result[:invoice_url])

    result
  rescue RateLimitError => e
    @error = :rate_limit
    Rails.logger.error("InvoiceUrlParserService rate limit: #{e.message}")
    empty_result
  rescue StandardError => e
    Rails.logger.error("InvoiceUrlParserService error: #{e.message}")
    empty_result
  end

  def rate_limited?
    @error == :rate_limit
  end

  private

  def empty_result
    { invoice_url: nil, invoice_data: {}, business_name: nil, qr_detected: false, platform: nil }
  end

  # Detect the invoicing platform from the URL using the registry
  def detect_platform(url)
    return nil unless url.present?
    key = InvoicePlatformRegistry.detect(url)
    key&.to_s || "generic"
  end

  def call_gemini_api
    uri = URI("#{GEMINI_API_URL}?key=#{api_key}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
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
          { text: "You are an expert at reading Mexican receipts and tickets. You specialize in finding invoice (factura) information including URLs, QR codes, RFC numbers, serie, folio numbers, and all data needed to generate a CFDI invoice." }
        ]
      }
    }
  end

  def prompt
    <<~PROMPT
      Analyze this Mexican receipt/ticket image carefully. Your goal is to extract ALL information needed to generate an invoice (factura/CFDI) from the invoicing portal.

      IMPORTANT: Mexican receipts usually have a "FACTURACIÓN" section at the bottom with specific data for generating invoices. Look for it carefully.

      This could be a RESTAURANT ticket, GAS STATION ticket, GROCERY STORE ticket, or any other type of business in Mexico.

      Extract the following:

      1. **Invoice URL**: The web URL for generating the invoice.
         - Often at the bottom: "FACTURAS:", "Si requiere factura", "Facturación:", "Para facturar"
         - Examples: "facturacion.alsuper.com", "http://mefacturo.mx/shhaciendas", "facturacion.hakunabolasdearroz.com", "facturacion.usfuel.com.mx"
         - Include the full URL exactly as printed
         - IMPORTANT: If the receipt shows "facturacion.BUSINESS.com", return "https://facturacion.BUSINESS.com" (subdomain format, NOT "BUSINESS.com/facturacion")

      2. **QR Code**: Whether a QR code for invoicing is visible on the receipt.

      3. **Invoice form data** (CRITICAL - these are the fields needed to fill the online invoice form):
         - "serie": The SERIE or store code (usually 4-8 letters, may be labeled "Serie:", "Tienda:", "Clave:")
           IMPORTANT: Serie is often ALL LETTERS. If you see what looks like a number mixed with letters, it's likely a letter that looks like a number in the receipt font (e.g., "8" might be "B", "0" might be "O", "1" might be "I").
         - "folio": The ticket/folio/cheque number (may be labeled "Ticket:", "Folio:", "Cheque:", "No. Ticket:")
           This is usually a NUMERIC code. If labeled "FACTURA00097402", the folio is just "00097402".
           For gas stations, this is often a long number like "0455754477110".
         - "importe": The total amount (number, may be labeled "Importe:", "Total:", "Total a pagar:")
         - "fecha": The date in YYYY-MM-DD format (may be labeled "Fecha:", "Fecha ticket:")
         - "rfc": The RFC of the business (NOT the customer's RFC)
         - "razon_social": Legal business name (e.g., "PRONTOGAS S.A. DE C.V.")
         - "sucursal": Store/branch name (e.g., "La Fuente", "Bahias", "Campus")
         - "sucursal_value": Numeric store/branch ID if visible (e.g., "004" from "Tienda #: 004")
         - "punto_venta": Point of sale number if visible (e.g., "01" from "Punto de Venta: 01")
         - "forma_pago": Payment method used. Return a SAT code:
           "01" = Efectivo/Cash, "04" = Tarjeta de crédito, "28" = Tarjeta de débito,
           "03" = Transferencia, "02" = Cheque, "99" = Por definir.
           Look for "Forma de Pago:", "Método:", "T. de crédito", etc.
         - "web_id": Any web ID, reference code, or PIN printed near the invoicing section.
           For gas stations like US Fuel: "Web ID: 33F4136"

      4. **Business name**: Short, clean name of the business (e.g., "US Fuel", "Hakuna Bolas de Arroz")

      Return a JSON object:
      {
        "invoice_url": "URL string or null",
        "qr_detected": true/false,
        "qr_context": "text near QR or null",
        "business_name": "short business name",
        "invoice_data": {
          "serie": "store/serie code (letters only for restaurant platforms, null if not found)",
          "folio": "ticket/folio number (null if not found)",
          "importe": total_amount_as_number_or_null,
          "fecha": "YYYY-MM-DD or null",
          "rfc": "business RFC or null",
          "razon_social": "legal name or null",
          "sucursal": "branch name or null",
          "sucursal_value": "numeric branch ID or null",
          "punto_venta": "point of sale number or null",
          "forma_pago": "SAT code (01/02/03/04/28/99) or null",
          "web_id": "web reference ID or null"
        }
      }

      CRITICAL RULES:
      - For restaurants: the serie field should contain ONLY LETTERS (A-Z). Convert any digit that is likely a misread letter.
      - For gas stations: the folio/ticket is a LONG numeric string (10+ digits).
      - The importe should be the final total amount as a number (no $ sign).
      - The fecha MUST be in YYYY-MM-DD format.
      - For supermarkets (Alsuper, Soriana, etc.): the importe is "Total Venta" (NOT "Total Pagado" which may include charity rounding).
        Also extract "Tienda #" or store number as sucursal_value, and "Punto de Venta" as punto_venta.
        The folio is the ticket number (labeled "Folio:" on the receipt).
      - Map "T. de crédito" or "Tarjeta de crédito" to forma_pago "04".
      - Map "T. de débito" or "Tarjeta de débito" to forma_pago "28".
      - Map "Efectivo" to forma_pago "01".
      - Look at the VERY BOTTOM of the ticket for the facturación section.
      - Return ONLY valid JSON.
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

      if error_code == 429 || error_message.include?("quota") || error_message.include?("rate")
        raise RateLimitError, error_message
      end

      Rails.logger.error("Gemini API error: #{error_message}")
      return empty_result
    end

    text = response.dig("candidates", 0, "content", "parts", 0, "text")
    return empty_result unless text

    clean_text = text.gsub(/```json\n?/, "").gsub(/```\n?/, "").strip
    parsed = JSON.parse(clean_text)

    {
      invoice_url: parsed["invoice_url"],
      qr_detected: parsed["qr_detected"] == true,
      qr_context: parsed["qr_context"],
      business_name: parsed["business_name"],
      invoice_data: (parsed["invoice_data"] || {}).transform_keys(&:to_sym)
    }
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse Gemini response: #{e.message}, text: #{text}")
    empty_result
  end

  def api_key
    ENV["GEMINI_API_KEY"] || Rails.application.credentials.dig(:gemini, :api_key)
  end
end
