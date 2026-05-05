require "net/http"
require "json"
require "uri"

# Submits invoice (factura) data to third-party invoice platforms server-side.
# This allows the mobile app to validate and submit ticket data without
# needing JavaScript injection or clipboard hacks.
#
# Supports: TimbraXML-powered sites (most common Mexican restaurant invoice platform)
#
# Full TimbraXML flow:
#   1. verify_ticket     — POST /facturacion/verificaParametros  (validate ticket data)
#   2. lookup_rfc        — POST /facturacion/getRFC              (validate RFC & get razón social)
#   3. get_select_options — POST /facturacion/getSelect           (get régimen & uso CFDI options)
#   4. generate_preview  — POST /facturacion/generarVistaPrevia  (generate invoice preview)
#   5. confirm_invoice   — POST /facturacion/verificaFactura     (confirm & stamp CFDI)
#   6. download_documents — POST /facturacion/documentos          (download PDF/XML)
#
# Usage:
#   service = InvoiceFormFillerService.new("https://facturacion.hakunabolasdearroz.com")
#
#   # Step 1: Verify ticket
#   result = service.verify_ticket(serie: "IBAFAE", folio: "00097402", importe: "348.00", fecha: "2026-02-23")
#   # => { success: true, cookies: {...} }
#
#   # Step 2: Lookup RFC (returns razón social, régimen, etc.)
#   rfc_result = service.lookup_rfc("XAXX010101000")
#   # => { success: true, data: { razon_social: "...", regimen: "..." } }
#
#   # Step 3: Generate preview
#   preview = service.generate_preview(serie: "IBAFAE", folio: "00097402", ...)
#   # => { success: true }
#
#   # Step 4: Confirm invoice (stamp CFDI)
#   invoice = service.confirm_invoice(...)
#   # => { success: true }
#
#   # Step 5: Download PDF/XML
#   docs = service.download_documents(serie: "IBAFAE", folio: "00097402")
#   # => { success: true, pdf_url: "...", xml_url: "..." }
#
class InvoiceFormFillerService
  TIMEOUT = 20 # seconds

  attr_reader :base_url, :platform
  attr_accessor :cookies

  def initialize(invoice_url, cookies: {})
    @base_url = normalize_base_url(invoice_url)
    @platform = InvoicePlatformRegistry.detect(invoice_url)
    @cookies = cookies || {}
  end

  # ─── Step 1: Verify ticket data ─────────────────────────────────────
  # Returns { success: true, cookies: {...} } or { success: false, error: "message" }
  def verify_ticket(serie:, folio:, importe:, fecha:)
    case @platform
    when :timbraxml
      verify_timbraxml(serie: serie, folio: folio, importe: importe, fecha: fecha)
    when :usfuel
      verify_usfuel(folio: folio, importe: importe, fecha: fecha)
    when :rfacil
      verify_rfacil(folio: folio, importe: importe, fecha: fecha, serie: serie)
    else
      { success: false, error: "Plataforma no soportada para verificación automática" }
    end
  end

  # ─── Step 2: Lookup RFC ─────────────────────────────────────────────
  # Validates an RFC and returns the associated razón social, régimen, etc.
  # Returns { success: true, data: { razon_social: "...", regimen: "601", ... } }
  def lookup_rfc(rfc)
    case @platform
    when :timbraxml
      timbraxml_get_rfc(rfc)
    when :usfuel
      usfuel_get_client(rfc)
    when :rfacil
      # rfácil doesn't have a separate RFC lookup — RFC is submitted with the form
      { success: true, data: {} }
    else
      { success: false, error: "Plataforma no soportada" }
    end
  end

  # ─── Step 2b: Get select options (régimen, uso CFDI) ────────────────
  # Returns available options for régimen fiscal and uso CFDI dropdowns.
  # These options depend on the RFC type (persona física vs moral).
  def get_select_options(rfc)
    case @platform
    when :timbraxml
      timbraxml_get_select(rfc)
    when :rfacil
      # rfácil handles CFDI details on their side — return standard SAT options
      { success: true, regimen_options: InvoicePlatformRegistry::REGIMEN_FISCAL_OPTIONS, uso_cfdi_options: InvoicePlatformRegistry::USO_CFDI_OPTIONS }
    else
      { success: false, error: "Plataforma no soportada" }
    end
  end

  # ─── Step 3: Generate invoice preview ───────────────────────────────
  # Sends personal data + ticket data to generate a preview of the CFDI.
  # Returns { success: true } or { success: false, error: "message" }
  def generate_preview(serie:, folio:, importe:, fecha:, rfc:, uso_cfdi:, forma_pago: "99")
    case @platform
    when :timbraxml
      timbraxml_generate_preview(
        serie: serie, folio: folio, importe: importe, fecha: fecha,
        rfc: rfc, uso_cfdi: uso_cfdi, forma_pago: forma_pago
      )
    when :usfuel
      # US Fuel no tiene paso de preview — va directo a timbrar
      { success: true }
    when :rfacil
      # rfácil is a single-step form — no separate preview
      { success: true }
    else
      { success: false, error: "Plataforma no soportada" }
    end
  end

  # ─── Step 4: Confirm and stamp CFDI ─────────────────────────────────
  # Confirms the invoice and triggers CFDI stamping (timbrado).
  # Returns { success: true } or { success: false, error: "message" }
  def confirm_invoice(serie:, folio:, importe:, fecha:, email:, rfc:, uso_cfdi:, forma_pago: "99", razon_social: "", regimen: "", codigo_postal: "", ticket_data: {}, estacion_data: {}, id_cliente: 0)
    case @platform
    when :timbraxml
      timbraxml_confirm_invoice(
        serie: serie, folio: folio, importe: importe, fecha: fecha,
        email: email, rfc: rfc, uso_cfdi: uso_cfdi, forma_pago: forma_pago
      )
    when :usfuel
      usfuel_timbrar(
        folio: folio, importe: importe, fecha: fecha,
        email: email, rfc: rfc, uso_cfdi: uso_cfdi, forma_pago: forma_pago,
        razon_social: razon_social, regimen: regimen, codigo_postal: codigo_postal,
        ticket_data: ticket_data, estacion_data: estacion_data, id_cliente: id_cliente
      )
    when :rfacil
      rfacil_submit_invoice(
        folio: folio, importe: importe, fecha: fecha,
        email: email, rfc: rfc
      )
    else
      { success: false, error: "Plataforma no soportada" }
    end
  end

  # ─── Step 5: Download documents (PDF/XML) ───────────────────────────
  # After successful timbrado, downloads the PDF and XML files.
  # Returns { success: true, pdf: <binary>, xml: <binary> } or error
  def download_documents(serie:, folio:)
    case @platform
    when :timbraxml
      timbraxml_download_documents(serie: serie, folio: folio)
    else
      { success: false, error: "Plataforma no soportada" }
    end
  end

  # ─── Recover existing invoice (US Fuel only) ────────────────────────
  # When a ticket is already invoiced, searches MisFacturas by RFC,
  # finds the matching invoice by folio, and retrieves the PDF/XML files.
  # Returns { success: true, pdf_base64: ..., xml_string: ..., uuid: ... }
  def recover_existing_invoice(folio:, rfc:, fecha:)
    case @platform
    when :usfuel
      usfuel_recover_existing_invoice(folio: folio, rfc: rfc, fecha: fecha)
    else
      { success: false, error: "Recuperación de facturas no soportada para esta plataforma." }
    end
  end

  # Stores rfácil-specific data from the ticket for use during form submission.
  # Called by the controller after parsing the ticket image.
  def rfacil_set_ticket_data(sucursal_value:, punto_venta:, rfc_emisor: nil)
    @rfacil_sucursal_value = sucursal_value.to_s
    @rfacil_punto_venta = punto_venta.to_s
    @rfacil_rfc_emisor = rfc_emisor if rfc_emisor.present?
    # Persist in cookies hash so they survive between requests
    @cookies["__rfacil_sucursal"] = @rfacil_sucursal_value
    @cookies["__rfacil_punto_venta"] = @rfacil_punto_venta
    @cookies["__rfacil_rfc_emisor"] = @rfacil_rfc_emisor if @rfacil_rfc_emisor
  end

  # Queries "Consultar Mis Facturas" on rfácil to find PDF/XML download links.
  # Called after successful invoice generation to provide backup files.
  # Returns { success: true, pdf_urls: [...], xml_urls: [...] } or { success: false }
  def fetch_mis_facturas(rfc:, email:)
    rfacil_fetch_mis_facturas(rfc: rfc, email: email)
  end

  private

  # ═══════════════════════════════════════════════════════════════════════
  # TimbraXML implementation
  # ═══════════════════════════════════════════════════════════════════════

  # POST /facturacion/verificaParametros
  def verify_timbraxml(serie:, folio:, importe:, fecha:)
    params = {
      "vista" => "2",
      "tienda" => serie.to_s.strip.upcase,
      "ticket" => folio.to_s.strip,
      "importe" => format_importe(importe),
      "fecha_ticket" => fecha.to_s.strip
    }

    result = post_to_platform("/facturacion/verificaParametros", params)
    return result unless result[:success]

    # Store cookies from the verification response for subsequent requests
    @cookies.merge!(result[:cookies] || {})
    result
  end

  # POST /facturacion/getRFC
  # Validates RFC and returns associated data (razón social, régimen, etc.)
  def timbraxml_get_rfc(rfc)
    params = { "aydi" => rfc.to_s.strip.upcase }
    result = post_to_platform("/facturacion/getRFC", params)
    return result unless result[:success]

    parsed = result[:parsed]
    if parsed.is_a?(Hash)
      {
        success: true,
        data: {
          razon_social: parsed["razon_social"] || parsed["nombre"],
          regimen: parsed["regimen"],
          codigo_postal: parsed["codigo_postal"] || parsed["cp"],
          rfc: parsed["rfc"] || rfc.to_s.strip.upcase
        }.compact
      }
    else
      { success: true, data: {} }
    end
  end

  # POST /facturacion/getSelect
  # Returns dropdown options for régimen fiscal and uso CFDI based on RFC
  def timbraxml_get_select(rfc)
    params = { "aydi" => rfc.to_s.strip.upcase }
    result = post_to_platform("/facturacion/getSelect", params)
    return result unless result[:success]

    parsed = result[:parsed]
    if parsed.is_a?(Hash)
      {
        success: true,
        regimen_options: parsed["regimen"] || [],
        uso_cfdi_options: parsed["uso_cfdi"] || []
      }
    elsif parsed.is_a?(Array)
      { success: true, options: parsed }
    else
      { success: true, options: [] }
    end
  end

  # POST /facturacion/generarVistaPrevia
  def timbraxml_generate_preview(serie:, folio:, importe:, fecha:, rfc:, uso_cfdi:, forma_pago:)
    params = {
      "forma_pago" => forma_pago.to_s,
      "folio" => folio.to_s.strip,
      "tienda" => serie.to_s.strip.upcase,
      "importe" => format_importe(importe),
      "fecha_ticket" => fecha.to_s.strip,
      "rfc" => rfc.to_s.strip.upcase,
      "uso_cfdi" => uso_cfdi.to_s.strip,
      "check_detalle" => "0"
    }

    post_to_platform("/facturacion/generarVistaPrevia", params)
  end

  # POST /facturacion/verificaFactura
  def timbraxml_confirm_invoice(serie:, folio:, importe:, fecha:, email:, rfc:, uso_cfdi:, forma_pago:)
    params = {
      "es_pago_app" => "0",
      "forma_pago_app" => "",
      "ticket" => folio.to_s.strip,
      "tienda" => serie.to_s.strip.upcase,
      "importe" => format_importe(importe),
      "fecha_ticket" => fecha.to_s.strip,
      "correo" => email.to_s.strip,
      "vista" => "2",
      "rfc" => rfc.to_s.strip.upcase,
      "uso_cfdi" => uso_cfdi.to_s.strip,
      "check_detalle" => "0",
      "archivoABorrar" => ""
    }

    post_to_platform("/facturacion/verificaFactura", params)
  end

  # POST /facturacion/documentos
  def timbraxml_download_documents(serie:, folio:)
    params = {
      "ticket" => folio.to_s.strip,
      "tienda" => serie.to_s.strip.upcase
    }

    post_to_platform("/facturacion/documentos", params)
  end

  # ═══════════════════════════════════════════════════════════════════════
  # US Fuel / Rendilitros implementation
  # Backend API: https://addesapi.rendilitros.com
  # ═══════════════════════════════════════════════════════════════════════

  USFUEL_API_BASE = "https://addesapi.rendilitros.com"
  USFUEL_AUTH = "Basic " + Base64.strict_encode64("Autofacturacion:AutoF@ctur4.2021$")

  # POST /api/Despacho/GetTicketWEB
  # US Fuel API wraps all request bodies in { "Data": { ... } } with PascalCase keys.
  # Returns the ticket object (Gasolinera, Transaccion, Despacho, Bomba, GranTotal, etc.)
  # which is needed later for Timbrar.
  def verify_usfuel(folio:, importe:, fecha:)
    params = {
      "Data" => {
        "Ticket" => folio.to_s.strip,
        "Total" => importe.to_f,
        "Fecha" => fecha.to_s.strip
      }
    }

    result = post_to_external(USFUEL_API_BASE, "/api/Despacho/GetTicketWEB", params, json_body: true)
    return result unless result[:success]

    parsed = result[:parsed]
    if parsed.is_a?(Hash) && parsed["Success"] == false
      return { success: false, error: parsed["Message"] || "Ticket no encontrado o ya fue facturado." }
    end

    # Store the full ticket response — Timbrar needs these fields
    result[:ticket_data] = parsed
    result
  end

  # POST /api/Estacion/GetEstacion
  # Gets station data needed for Timbrar. The station number is extracted from the ticket number.
  def usfuel_get_estacion(folio)
    # Station number is the first 4 digits of the ticket
    no_estacion = folio.to_s.strip[0, 4]

    result = post_to_external(
      USFUEL_API_BASE,
      "/api/Estacion/GetEstacion",
      { "noEstacion" => no_estacion },
      json_body: false # This endpoint uses form-urlencoded
    )
    return result unless result[:success]

    result[:estacion_data] = result[:parsed]
    result
  end

  # GET /api/Cliente/GetClienteByRFC?rfc=XXX
  def usfuel_get_client(rfc)
    result = get_from_external(USFUEL_API_BASE, "/api/Cliente/GetClienteByRFC", { "rfc" => rfc.to_s.strip.upcase })
    return result unless result[:success]

    parsed = result[:parsed]
    if parsed.is_a?(Hash)
      {
        success: true,
        data: {
          razon_social: parsed["nombre"] || parsed["razon_social"] || parsed["Name"] || parsed["Nombre"],
          regimen: parsed["regimen"] || parsed["FiscalRegime"] || parsed["RegimenFiscal"],
          codigo_postal: parsed["cp"] || parsed["codigo_postal"] || parsed["TaxZipCode"] || parsed["CodigoPostal"],
          id_cliente: parsed["idCliente"] || parsed["IdCliente"] || parsed["id"],
          rfc: parsed["rfc"] || parsed["Rfc"] || parsed["RFC"] || rfc.to_s.strip.upcase
        }.compact
      }
    else
      { success: true, data: {} }
    end
  end

  # POST /api/CFDI40/Timbrar  (note: CFDI40, not CFDI)
  # Requires ticket data from GetTicketWEB + station data from GetEstacion + fiscal data.
  # Returns PdfBase64 + XML in the response.
  def usfuel_timbrar(folio:, importe:, fecha:, email:, rfc:, uso_cfdi:, forma_pago:, razon_social:, regimen:, codigo_postal:, ticket_data: {}, estacion_data: {}, id_cliente: 0)
    # Build the complete Timbrar body with all required fields
    params = {
      "Data" => {
        # Ticket fields from GetTicketWEB response
        "Gasolinera" => ticket_data["Gasolinera"] || ticket_data["gasolinera"] || "",
        "Estacion" => estacion_data["UsFuel"] || estacion_data["Estacion"] || "",
        "NoEstacion" => estacion_data["NoEstacion"] || folio.to_s.strip[0, 4],
        "Despacho" => ticket_data["Despacho"] || ticket_data["despacho"] || folio.to_s.strip,
        "Transaccion" => ticket_data["Transaccion"] || ticket_data["transaccion"] || "",
        "tipoComprobante" => "I",
        # Client fields
        "IdCliente" => id_cliente.to_i,
        "RFC" => rfc.to_s.strip.upcase,
        "Nombre" => razon_social.to_s.strip,
        "UsoCFDI" => uso_cfdi.to_s.strip,
        "Correo" => email.to_s.strip,
        "FormaPago" => forma_pago.to_s.strip,
        "Usuario" => "Autofacturacion",
        "DomicilioFiscalReceptor" => codigo_postal.to_s.strip,
        "RegimenFiscalReceptor" => regimen.to_s.strip,
        "OcultarCampos" => true
      }
    }

    result = post_to_external(USFUEL_API_BASE, "/api/CFDI40/Timbrar", params, json_body: true)
    return result unless result[:success]

    parsed = result[:parsed]
    if parsed.is_a?(Hash)
      if parsed["Success"] == false
        return { success: false, error: parsed["Message"] || parsed["Error"] || "Error al timbrar la factura." }
      end

      # Extract PDF (base64) and XML from the response
      result[:pdf_base64] = parsed["PdfBase64"]
      result[:xml_string] = parsed["XML"]
    end

    result
  end

  # POST /api/CFDI/GetMisFacturas
  # Searches for existing invoices by RFC within a date range.
  # Returns a list of invoices with Folio, UUID, Estacion, Serie, Fecha, Estatus.
  def usfuel_get_mis_facturas(rfc:, fecha_inicial:, fecha_final:)
    params = {
      "Data" => {
        "RFC" => rfc.to_s.strip.upcase,
        "FechaInicial" => fecha_inicial.to_s.strip,
        "FechaFinal" => fecha_final.to_s.strip
      }
    }

    Rails.logger.info("InvoiceFormFiller: GetMisFacturas body=#{params.to_json}")

    result = post_to_external(USFUEL_API_BASE, "/api/CFDI/GetMisFacturas", params, json_body: true)
    return result unless result[:success]

    parsed = result[:parsed]
    if parsed.is_a?(Hash)
      facturas = parsed["response"]
      if facturas.is_a?(Array)
        result[:facturas] = facturas
      else
        result[:facturas] = []
      end
      # Log for debugging
      Rails.logger.info("InvoiceFormFiller: GetMisFacturas found #{result[:facturas].size} facturas (Success=#{parsed['Success']})")
    end

    result
  end

  # POST /api/CFDI/GetArchivosCFDI?UUID=<uuid>
  # Retrieves PDF and XML files for an existing invoice by UUID.
  # Returns { response: { PDF: <base64>, XML: <string> } }
  def usfuel_get_archivos_cfdi(uuid:)
    result = post_to_external(
      USFUEL_API_BASE,
      "/api/CFDI/GetArchivosCFDI?UUID=#{URI.encode_www_form_component(uuid)}",
      {},
      json_body: true
    )
    return result unless result[:success]

    parsed = result[:parsed]
    if parsed.is_a?(Hash) && parsed["Success"] == true
      response_data = parsed["response"] || parsed["Response"] || {}
      result[:pdf_base64] = response_data["PDF"]
      result[:xml_string] = response_data["XML"]
    elsif parsed.is_a?(Hash)
      return { success: false, error: parsed["Message"] || "No se pudieron obtener los archivos." }
    end

    result
  end

  # POST /api/CFDI/SendCFDI
  # Resends the invoice email for an existing invoice by UUID.
  def usfuel_send_cfdi(uuid:, correo:)
    params = {
      "Data" => {
        "UUID" => uuid.to_s.strip,
        "Correo" => correo.to_s.strip
      }
    }

    post_to_external(USFUEL_API_BASE, "/api/CFDI/SendCFDI", params, json_body: true)
  end

  # High-level: Given a ticket folio and RFC, find the existing invoice and retrieve its files.
  # Used when a ticket is already invoiced — searches MisFacturas, matches by Folio, downloads files.
  def usfuel_recover_existing_invoice(folio:, rfc:, fecha:)
    # Search invoices in a wide date range around the ticket date
    begin
      ticket_date = Date.parse(fecha.to_s)
    rescue
      ticket_date = Date.today
    end
    fecha_inicial = (ticket_date - 30).strftime("%Y-%m-%d")
    fecha_final = (ticket_date + 1).strftime("%Y-%m-%d")

    facturas_result = usfuel_get_mis_facturas(rfc: rfc, fecha_inicial: fecha_inicial, fecha_final: fecha_final)
    unless facturas_result[:success]
      return { success: false, error: "No se pudieron consultar las facturas existentes: #{facturas_result[:error]}" }
    end

    facturas = facturas_result[:facturas] || []
    Rails.logger.info("InvoiceFormFiller: Searching #{facturas.size} facturas for folio=#{folio}")

    # Match by Folio (ticket number) — Folio may be stored with or without leading zeros
    # Also try matching by Despacho field since some invoices use that instead
    folio_clean = folio.to_s.strip
    matching = facturas.find do |f|
      f_folio = (f["Folio"] || f["folio"] || f["Despacho"] || f["despacho"]).to_s.strip
      f_folio == folio_clean || f_folio.gsub(/\A0+/, "") == folio_clean.gsub(/\A0+/, "")
    end

    # If no match found, log available folios for debugging
    unless matching
      available = facturas.first(5).map { |f| "Folio=#{f['Folio']} Despacho=#{f['Despacho']}" }.join(", ")
      Rails.logger.info("InvoiceFormFiller: No match for folio #{folio_clean}. Available: #{available}")

      # If no facturas at all, try with a much wider date range (90 days)
      if facturas.empty?
        fecha_inicial_wide = (ticket_date - 90).strftime("%Y-%m-%d")
        fecha_final_wide = (Date.today + 1).strftime("%Y-%m-%d")
        Rails.logger.info("InvoiceFormFiller: Retrying GetMisFacturas with wider range: #{fecha_inicial_wide} to #{fecha_final_wide}")

        facturas_result2 = usfuel_get_mis_facturas(rfc: rfc, fecha_inicial: fecha_inicial_wide, fecha_final: fecha_final_wide)
        if facturas_result2[:success]
          facturas = facturas_result2[:facturas] || []
          matching = facturas.find do |f|
            f_folio = (f["Folio"] || f["folio"] || f["Despacho"] || f["despacho"]).to_s.strip
            f_folio == folio_clean || f_folio.gsub(/\A0+/, "") == folio_clean.gsub(/\A0+/, "")
          end
        end
      end

      unless matching
        if facturas.empty?
          return { success: false, error: "No se encontraron facturas para este RFC en el sistema. Es posible que el ticket se haya marcado como usado sin generar factura. Contacta a la estación para solicitar la liberación del ticket." }
        else
          return { success: false, error: "Se encontraron #{facturas.size} facturas para este RFC, pero ninguna coincide con el ticket #{folio_clean}." }
        end
      end
    end

    uuid = matching["UUID"] || matching["uuid"]
    unless uuid.present?
      return { success: false, error: "No se encontró el UUID de la factura." }
    end

    # Retrieve the PDF and XML files
    archivos_result = usfuel_get_archivos_cfdi(uuid: uuid)
    unless archivos_result[:success]
      return { success: false, error: archivos_result[:error] || "No se pudieron descargar los archivos." }
    end

    {
      success: true,
      already_invoiced: true,
      uuid: uuid,
      factura: matching,
      pdf_base64: archivos_result[:pdf_base64],
      xml_string: archivos_result[:xml_string]
    }
  end

  # ═══════════════════════════════════════════════════════════════════════
  # rfácil (ASP.NET WebForms) implementation
  # Used by: Alsuper Plus and others using the rfácil invoicing platform.
  # Flow: GET page → extract ViewState tokens → POST with form data + tokens
  # ═══════════════════════════════════════════════════════════════════════

  # For rfácil, "verify" means fetching the form page and storing the ASP.NET
  # ViewState tokens needed for the actual form submission. We also validate
  # that we can reach the platform and that the sucursal dropdown is available.
  def verify_rfacil(folio:, importe:, fecha:, serie:)
    config = InvoicePlatformRegistry.config_for(:rfacil)
    form_url = "#{@base_url}#{config[:form_path]}"

    Rails.logger.info("InvoiceFormFiller [rfácil]: GET #{form_url} to extract ViewState tokens")

    uri = URI(form_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = TIMEOUT
    http.open_timeout = TIMEOUT

    request = Net::HTTP::Get.new(uri.request_uri)
    request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    request["Accept"] = "text/html,application/xhtml+xml"
    request["Cookie"] = format_cookies if @cookies.any?

    response = http.request(request)
    body = response.body.to_s.force_encoding("UTF-8")
    body.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "?")

    Rails.logger.info("InvoiceFormFiller [rfácil]: GET response #{response.code}, body length=#{body.length}")

    unless response.code.to_i == 200
      return { success: false, error: "No se pudo acceder al portal de facturación (HTTP #{response.code})" }
    end

    # Extract ASP.NET hidden fields
    viewstate = extract_aspnet_field(body, "__VIEWSTATE")
    viewstate_gen = extract_aspnet_field(body, "__VIEWSTATEGENERATOR")
    event_validation = extract_aspnet_field(body, "__EVENTVALIDATION")

    if viewstate.blank?
      Rails.logger.error("InvoiceFormFiller [rfácil]: Could not extract __VIEWSTATE from page")
      return { success: false, error: "No se pudieron obtener los tokens del formulario. La página puede haber cambiado." }
    end

    # Extract the form action URL (may include query string like ?ReturnUrl=%2f)
    form_action_match = body.match(/<form[^>]*action="([^"]*)"/)
    if form_action_match
      raw_action = form_action_match[1]
      # Resolve relative action (e.g., "./IniciaAutoFacturacion.aspx?ReturnUrl=%2f")
      if raw_action.start_with?("./")
        @rfacil_form_action = "#{config[:form_path].sub(/[^\/]+$/, '')}#{raw_action.sub('./', '')}"
      elsif raw_action.start_with?("/")
        @rfacil_form_action = raw_action
      else
        @rfacil_form_action = "#{config[:form_path].sub(/[^\/]+$/, '')}#{raw_action}"
      end
      Rails.logger.info("InvoiceFormFiller [rfácil]: Form action extracted: #{@rfacil_form_action}")
    else
      @rfacil_form_action = config[:form_path]
    end

    # Extract the pre-filled RFC emisor from the form (more reliable than OCR)
    rfc_emisor_match = body.match(/id="txtRFCEmisor"[^>]*value="([^"]*)"/)
    if rfc_emisor_match && rfc_emisor_match[1].present?
      @rfacil_rfc_emisor = rfc_emisor_match[1]
      Rails.logger.info("InvoiceFormFiller [rfácil]: RFC emisor from form: #{@rfacil_rfc_emisor}")
    end

    # Store tokens in memory only (NOT in @cookies — ViewState is ~17KB and would
    # overflow the Rails session cookie which has a 4KB limit).
    # The submit step will re-fetch fresh tokens via verify_rfacil.
    @rfacil_viewstate = viewstate
    @rfacil_viewstate_gen = viewstate_gen
    @rfacil_event_validation = event_validation

    # Extract and store real HTTP cookies (small, safe for session)
    new_cookies = extract_cookies(response)
    @cookies.merge!(new_cookies)

    Rails.logger.info("InvoiceFormFiller [rfácil]: Extracted ViewState (len=#{viewstate.length}), EventValidation (len=#{event_validation&.length})")

    { success: true }
  rescue Net::ReadTimeout, Net::OpenTimeout
    { success: false, error: "El portal de facturación no respondió. Intenta de nuevo." }
  rescue StandardError => e
    Rails.logger.error("InvoiceFormFiller [rfácil] verify error: #{e.message}")
    { success: false, error: "Error de conexión: #{e.message}" }
  end

  # Submits the rfácil invoice form with all required data.
  # This POSTs the ASP.NET form with ViewState tokens + form field values.
  # The response HTML is parsed for success/error messages.
  RFACIL_TIMEOUT = 45 # rfácil/ASP.NET can be slow

  def rfacil_submit_invoice(folio:, importe:, fecha:, email:, rfc:)
    config = InvoicePlatformRegistry.config_for(:rfacil)

    # Always fetch fresh ViewState tokens (they're ~17KB and can't be stored in session).
    # This also extracts the correct form action URL (with query string).
    verify_result = verify_rfacil(folio: folio, importe: importe, fecha: fecha, serie: "")
    return verify_result unless verify_result[:success]

    # Use the form action URL extracted from the HTML (includes ?ReturnUrl=%2f)
    form_action = @rfacil_form_action || config[:form_path]
    form_url = "#{@base_url}#{form_action}"

    # Resolve sucursal dropdown value from stored invoice data (memory or cookies)
    sucursal_value = @rfacil_sucursal_value || @cookies["__rfacil_sucursal"] || ""
    punto_venta = @rfacil_punto_venta || @cookies["__rfacil_punto_venta"] || "01"
    @rfacil_rfc_emisor ||= @cookies["__rfacil_rfc_emisor"]

    # Format fecha for rfácil (DD/MM/YYYY from YYYY-MM-DD)
    fecha_formatted = rfacil_format_fecha(fecha)

    # Format importe
    importe_formatted = format_importe(importe)

    # Build the ASP.NET postback form data
    form_data = {
      "__LASTFOCUS" => "",
      "__EVENTTARGET" => config[:submit_button],
      "__EVENTARGUMENT" => "",
      "__VIEWSTATE" => @rfacil_viewstate,
      "__VIEWSTATEGENERATOR" => @rfacil_viewstate_gen || "",
      "__EVENTVALIDATION" => @rfacil_event_validation || "",
      config[:fields][:rfc_emisor][:name] => @rfacil_rfc_emisor || "OFU910626UQ0",
      config[:fields][:sucursal][:name] => sucursal_value,
      config[:fields][:rfc_receptor][:name] => rfc,
      config[:fields][:folio][:name] => folio,
      config[:fields][:punto_venta][:name] => punto_venta,
      config[:fields][:fecha][:name] => fecha_formatted,
      config[:fields][:importe][:name] => importe_formatted,
      config[:fields][:email][:name] => email
    }

    Rails.logger.info("InvoiceFormFiller [rfácil]: POST #{form_url} — folio=#{folio}, sucursal=#{sucursal_value}, rfc=#{rfc}, fecha=#{fecha_formatted}, importe=#{importe_formatted}, email=#{email}")

    uri = URI(form_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = RFACIL_TIMEOUT
    http.open_timeout = RFACIL_TIMEOUT

    # Use request_uri (path + query string) — ASP.NET requires the ?ReturnUrl= param
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
    request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    request["Accept-Language"] = "es-MX,es;q=0.9,en;q=0.8"
    request["Cache-Control"] = "no-cache"
    request["Origin"] = @base_url
    request["Referer"] = form_url
    request["Cookie"] = format_cookies if @cookies.any?
    request.body = URI.encode_www_form(form_data)

    response = http.request(request)
    body = response.body.to_s.force_encoding("UTF-8")
    body.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "?")

    Rails.logger.info("InvoiceFormFiller [rfácil]: POST response #{response.code}, body length=#{body.length}")

    new_cookies = extract_cookies(response)
    @cookies.merge!(new_cookies)

    # Parse response HTML for success or error
    rfacil_parse_response(body, response)
  rescue Net::ReadTimeout, Net::OpenTimeout
    { success: false, error: "El portal de facturación no respondió. Intenta de nuevo." }
  rescue StandardError => e
    Rails.logger.error("InvoiceFormFiller [rfácil] submit error: #{e.class}: #{e.message}")
    { success: false, error: "Error de conexión: #{e.message}" }
  end

  # After successful invoice generation, queries "Consultar Mis Facturas" to find
  # download links for the generated PDF/XML files.
  # Flow: GET form → POST with RFC+email+btnMisFacturas → parse response for links
  def rfacil_fetch_mis_facturas(rfc:, email:)
    config = InvoicePlatformRegistry.config_for(:rfacil)
    form_url = "#{@base_url}#{config[:form_path]}"

    # GET fresh form page for new ViewState tokens
    Rails.logger.info("InvoiceFormFiller [rfácil]: Fetching Mis Facturas for RFC=#{rfc}")

    uri = URI(form_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = RFACIL_TIMEOUT
    http.open_timeout = RFACIL_TIMEOUT

    # GET the form page
    get_request = Net::HTTP::Get.new(uri.request_uri)
    get_request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    get_request["Accept"] = "text/html"
    get_request["Cookie"] = format_cookies if @cookies.any?

    get_response = http.request(get_request)
    get_body = get_response.body.to_s.force_encoding("UTF-8")
    get_body.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "?")

    new_cookies = extract_cookies(get_response)
    @cookies.merge!(new_cookies)

    viewstate = extract_aspnet_field(get_body, "__VIEWSTATE")
    viewstate_gen = extract_aspnet_field(get_body, "__VIEWSTATEGENERATOR")
    event_validation = extract_aspnet_field(get_body, "__EVENTVALIDATION")

    unless viewstate.present?
      Rails.logger.warn("InvoiceFormFiller [rfácil]: Could not get ViewState for Mis Facturas")
      return { success: false }
    end

    # POST with RFC + email + btnMisFacturas (submit button)
    form_data = {
      "__LASTFOCUS" => "",
      "__EVENTTARGET" => "",
      "__EVENTARGUMENT" => "",
      "__VIEWSTATE" => viewstate,
      "__VIEWSTATEGENERATOR" => viewstate_gen || "",
      "__EVENTVALIDATION" => event_validation || "",
      config[:fields][:rfc_emisor][:name] => @rfacil_rfc_emisor || "OFU910626UQ0",
      config[:fields][:sucursal][:name] => "",
      config[:fields][:rfc_receptor][:name] => rfc,
      config[:fields][:folio][:name] => "",
      config[:fields][:punto_venta][:name] => "",
      config[:fields][:fecha][:name] => "",
      config[:fields][:importe][:name] => "",
      config[:fields][:email][:name] => email,
      "ClWCAutoFacturaPortal2$btnMisFacturas" => "Consultar Mis Facturas"
    }

    post_request = Net::HTTP::Post.new(uri.request_uri)
    post_request["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
    post_request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    post_request["Accept"] = "text/html"
    post_request["Referer"] = form_url
    post_request["Origin"] = @base_url
    post_request["Cookie"] = format_cookies if @cookies.any?
    post_request.body = URI.encode_www_form(form_data)

    post_response = http.request(post_request)
    post_body = post_response.body.to_s.force_encoding("UTF-8")
    post_body.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "?")

    Rails.logger.info("InvoiceFormFiller [rfácil]: Mis Facturas response #{post_response.code}, body length=#{post_body.length}")

    new_cookies = extract_cookies(post_response)
    @cookies.merge!(new_cookies)

    # Follow redirect if needed
    if post_response.code.to_i.between?(300, 399)
      redirect_url = "#{@base_url}#{post_response['Location']}"
      Rails.logger.info("InvoiceFormFiller [rfácil]: Mis Facturas redirect to #{redirect_url}")
      redirect_uri = URI(redirect_url)
      redirect_req = Net::HTTP::Get.new(redirect_uri.request_uri)
      redirect_req["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
      redirect_req["Cookie"] = format_cookies if @cookies.any?
      redirect_response = http.request(redirect_req)
      post_body = redirect_response.body.to_s.force_encoding("UTF-8")
      post_body.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "?")
      Rails.logger.info("InvoiceFormFiller [rfácil]: Redirect response #{redirect_response.code}, body length=#{post_body.length}")
      new_cookies = extract_cookies(redirect_response)
      @cookies.merge!(new_cookies)
    end

    # Parse response for download links (PDF/XML)
    pdf_links = post_body.scan(/href="([^"]*\.pdf[^"]*)"/)
    xml_links = post_body.scan(/href="([^"]*\.xml[^"]*)"/)
    # Also look for __doPostBack-based download links
    download_links = post_body.scan(/href="javascript:__doPostBack\('([^']+)','([^']*)'\)"/)

    Rails.logger.info("InvoiceFormFiller [rfácil]: Found #{pdf_links.length} PDF links, #{xml_links.length} XML links, #{download_links.length} postback links")

    # Log any table/grid content that might contain invoice rows
    grid_rows = post_body.scan(/<tr[^>]*>.*?<\/tr>/m).select { |r| r.include?("PACE8204") || r.include?(rfc) }
    Rails.logger.info("InvoiceFormFiller [rfácil]: Grid rows matching RFC: #{grid_rows.length}")
    grid_rows.first(3).each_with_index do |row, i|
      clean = row.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
      Rails.logger.info("InvoiceFormFiller [rfácil]: Row #{i}: #{clean[0..200]}")
    end

    {
      success: pdf_links.any? || xml_links.any? || download_links.any?,
      pdf_urls: pdf_links.flatten.map { |l| l.start_with?("http") ? l : "#{@base_url}#{l}" },
      xml_urls: xml_links.flatten.map { |l| l.start_with?("http") ? l : "#{@base_url}#{l}" },
      download_links: download_links,
      body_preview: post_body[0..500]
    }
  rescue StandardError => e
    Rails.logger.error("InvoiceFormFiller [rfácil] fetch_mis_facturas error: #{e.class}: #{e.message}")
    { success: false, error: e.message }
  end

  # Extracts a hidden ASP.NET field value from HTML
  def extract_aspnet_field(html, field_name)
    # Match: <input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="..." />
    match = html.match(/name="#{Regexp.escape(field_name)}"[^>]*value="([^"]*)"/)
    match ||= html.match(/id="#{Regexp.escape(field_name)}"[^>]*value="([^"]*)"/)
    match ? match[1] : nil
  end

  # Parses rfácil response HTML after form submission.
  # Looks for success indicators (redirect to download page, success message)
  # or error messages (validation errors, modal popups).
  def rfacil_parse_response(html, response)
    # Check for HTTP-level redirects (302/301) — usually means success
    if response.code.to_i.between?(300, 399)
      location = response["Location"].to_s
      Rails.logger.info("InvoiceFormFiller [rfácil]: Redirect to #{location}")
      return { success: true, redirect_url: location }
    end

    # Look for common error patterns in rfácil responses
    # Modal popup errors (ctl01/ctl02 are ModalPopupExtender panels)
    error_match = html.match(/id="ClWCAutoFacturaPortal2_ctl01_lblMensaje"[^>]*>([^<]+)</)
    error_match ||= html.match(/id="ClWCAutoFacturaPortal2_ctl02_lblMensaje"[^>]*>([^<]+)</)
    # Also check for generic alert/error panels
    error_match ||= html.match(/class="[^"]*error[^"]*"[^>]*>([^<]{5,200})</)
    error_match ||= html.match(/class="[^"]*alert[^"]*"[^>]*>([^<]{5,200})</)

    if error_match
      error_msg = error_match[1].strip
      Rails.logger.warn("InvoiceFormFiller [rfácil]: Error message found: #{error_msg}")
      return { success: false, error: error_msg }
    end

    # Look for success indicators
    # rfácil typically shows a "Factura generada" message or a download link
    if html.include?("Factura generada") || html.include?("factura exitosa") ||
       html.include?("Se ha generado") || html.include?("Descargar")
      Rails.logger.info("InvoiceFormFiller [rfácil]: Success — invoice generated")

      # Try to extract PDF/XML download links
      pdf_link = html.match(/href="([^"]*\.pdf[^"]*)"/)
      xml_link = html.match(/href="([^"]*\.xml[^"]*)"/)

      return {
        success: true,
        message: "Factura generada exitosamente por rfácil.",
        pdf_url: pdf_link ? "#{@base_url}#{pdf_link[1]}" : nil,
        xml_url: xml_link ? "#{@base_url}#{xml_link[1]}" : nil
      }
    end

    # If the response contains a new ViewState, it might mean validation errors
    # but no explicit error message was found.
    if html.include?("__VIEWSTATE")
      # Page re-rendered — likely a validation error we couldn't parse
      Rails.logger.warn("InvoiceFormFiller [rfácil]: Page re-rendered (ViewState present). Possible validation error.")

      # Log all text inside modal popup panels (ctl01/ctl02 are ModalPopupExtender panels)
      # and any spans with error-like content
      modal_texts = html.scan(/id="ClWCAutoFacturaPortal2[^"]*lbl[^"]*"[^>]*>([^<]+)</).flatten
      Rails.logger.warn("InvoiceFormFiller [rfácil]: Modal/label texts: #{modal_texts.inspect}")

      # Log all visible spans that might contain error messages
      span_texts = html.scan(/<span[^>]*>([^<]{3,200})<\/span>/).flatten.reject { |t| t.strip.empty? || t.include?("__") }
      Rails.logger.warn("InvoiceFormFiller [rfácil]: Span texts: #{span_texts.first(20).inspect}")

      # Look for specific error messages in spans (e.g., "Error en validación de datos: ...")
      specific_error = span_texts.find { |t| t.strip.downcase.include?("error") }
      if specific_error
        return { success: false, error: specific_error.strip }
      end

      # Try to find any visible error text in common ASP.NET validator patterns
      validator_error = html.match(/<span[^>]*style="[^"]*color:\s*[Rr]ed[^"]*"[^>]*>([^<]+)</)
      validator_error ||= html.match(/<span[^>]*class="[^"]*validator[^"]*"[^>]*>([^<]+)</)

      if validator_error
        return { success: false, error: validator_error[1].strip }
      end

      # Check modal popup labels for error messages (skip generic titles like "Información del Sistema")
      modal_error = modal_texts.find { |t| t.strip.length > 3 && !t.include?("Información del Sistema") }
      if modal_error
        return { success: false, error: modal_error.strip }
      end

      return { success: false, error: "La página se recargó sin confirmar la factura. Revisa los datos e intenta de nuevo." }
    end

    # Fallback
    Rails.logger.warn("InvoiceFormFiller [rfácil]: Unexpected response (code=#{response.code})")
    { success: false, error: "Respuesta inesperada del portal de facturación." }
  end

  # Converts YYYY-MM-DD to DD/MM/YYYY for rfácil date fields
  def rfacil_format_fecha(fecha)
    parts = fecha.to_s.split("-")
    return fecha if parts.length != 3
    "#{parts[2]}/#{parts[1]}/#{parts[0]}"
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Shared HTTP helpers
  # ═══════════════════════════════════════════════════════════════════════

  # POST to an external API (different base URL than the invoice site)
  def post_to_external(api_base, path, params, json_body: false)
    endpoint = "#{api_base}#{path}"
    uri = URI(endpoint)

    Rails.logger.info("InvoiceFormFiller: POST #{endpoint} with #{params.keys.join(', ')}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = TIMEOUT
    http.open_timeout = TIMEOUT

    request = Net::HTTP::Post.new(uri.path)
    request["Accept"] = "application/json"
    request["X-Requested-With"] = "XMLHttpRequest"
    request["Origin"] = @base_url
    request["Referer"] = @base_url
    request["Cookie"] = format_cookies if @cookies.any?
    request["Authorization"] = USFUEL_AUTH if @platform == :usfuel

    if json_body
      request["Content-Type"] = "application/json"
      request.body = params.to_json
    else
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(params)
    end

    response = http.request(request)
    body = response.body.to_s.strip

    Rails.logger.info("InvoiceFormFiller: Response #{response.code}: #{body.truncate(300)}")

    new_cookies = extract_cookies(response)
    @cookies.merge!(new_cookies)

    parsed = begin
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    if parsed.is_a?(Hash) && parsed["error"].present?
      { success: false, error: parsed["error"] }
    elsif response.code.to_i == 200
      { success: true, cookies: new_cookies, parsed: parsed, body: body }
    else
      { success: false, error: "Error del servidor (HTTP #{response.code})" }
    end
  rescue Net::ReadTimeout, Net::OpenTimeout
    { success: false, error: "El servidor no respondió. Intenta de nuevo." }
  rescue StandardError => e
    Rails.logger.error("InvoiceFormFiller error: #{e.message}")
    { success: false, error: "Error de conexión: #{e.message}" }
  end

  # GET from an external API
  def get_from_external(api_base, path, params = {})
    query = params.any? ? "?#{URI.encode_www_form(params)}" : ""
    endpoint = "#{api_base}#{path}#{query}"
    uri = URI(endpoint)

    Rails.logger.info("InvoiceFormFiller: GET #{endpoint}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = TIMEOUT
    http.open_timeout = TIMEOUT

    request = Net::HTTP::Get.new(uri.request_uri)
    request["Accept"] = "application/json"
    request["X-Requested-With"] = "XMLHttpRequest"
    request["Origin"] = @base_url
    request["Referer"] = @base_url
    request["Cookie"] = format_cookies if @cookies.any?
    request["Authorization"] = USFUEL_AUTH if @platform == :usfuel

    response = http.request(request)
    body = response.body.to_s.strip

    Rails.logger.info("InvoiceFormFiller: Response #{response.code}: #{body.truncate(300)}")

    new_cookies = extract_cookies(response)
    @cookies.merge!(new_cookies)

    parsed = begin
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    if parsed.is_a?(Hash) && parsed["error"].present?
      { success: false, error: parsed["error"] }
    elsif response.code.to_i == 200
      { success: true, cookies: new_cookies, parsed: parsed, body: body }
    else
      { success: false, error: "Error del servidor (HTTP #{response.code})" }
    end
  rescue Net::ReadTimeout, Net::OpenTimeout
    { success: false, error: "El servidor no respondió. Intenta de nuevo." }
  rescue StandardError => e
    Rails.logger.error("InvoiceFormFiller error: #{e.message}")
    { success: false, error: "Error de conexión: #{e.message}" }
  end

  def post_to_platform(path, params)
    endpoint = "#{@base_url}#{path}"
    uri = URI(endpoint)

    Rails.logger.info("InvoiceFormFiller: POST #{endpoint} with #{params.keys.join(', ')}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = TIMEOUT
    http.open_timeout = TIMEOUT

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/x-www-form-urlencoded"
    request["Accept"] = "application/json"
    request["X-Requested-With"] = "XMLHttpRequest"
    request["Referer"] = @base_url
    request["Cookie"] = format_cookies if @cookies.any?
    request.body = URI.encode_www_form(params)

    response = http.request(request)
    body = response.body.to_s.strip

    Rails.logger.info("InvoiceFormFiller: Response #{response.code}: #{body.truncate(300)}")

    # Accumulate cookies from every response
    new_cookies = extract_cookies(response)
    @cookies.merge!(new_cookies)

    parsed = begin
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    if parsed.is_a?(Hash) && parsed["error"].present?
      { success: false, error: parsed["error"] }
    elsif response.code.to_i == 200
      { success: true, cookies: new_cookies, parsed: parsed, body: body }
    else
      { success: false, error: "Error del servidor (HTTP #{response.code})" }
    end
  rescue Net::ReadTimeout, Net::OpenTimeout
    { success: false, error: "El servidor de facturación no respondió. Intenta de nuevo." }
  rescue StandardError => e
    Rails.logger.error("InvoiceFormFiller error: #{e.message}")
    { success: false, error: "Error de conexión: #{e.message}" }
  end

  # Known URL corrections for rfácil sites where the receipt URL
  # differs from the actual facturación subdomain.
  # Map: pattern in URL → correct base URL (scheme + host)
  RFACIL_URL_CORRECTIONS = {
    "alsuper" => "https://facturacion.alsuper.com"
  }.freeze

  def normalize_base_url(url)
    url = "https://#{url}" unless url.start_with?("http://", "https://")
    url = url.chomp("/")

    # For rfácil sites: correct the base URL if the receipt URL has a wrong format
    # (e.g., "alsuper.com/facturacion" instead of "facturacion.alsuper.com")
    RFACIL_URL_CORRECTIONS.each do |pattern, correct_base|
      if url.include?(pattern)
        return correct_base
      end
    end

    # For other platforms: extract origin (scheme + host) to avoid path pollution
    uri = URI(url)
    if uri.host.present?
      port_str = (uri.port && ![80, 443].include?(uri.port)) ? ":#{uri.port}" : ""
      "#{uri.scheme}://#{uri.host}#{port_str}"
    else
      url
    end
  end

  def format_importe(importe)
    format("%.2f", importe.to_f)
  end

  def format_cookies
    @cookies
      .reject { |k, _| k.to_s.start_with?("__rfacil_") }
      .map { |k, v| "#{k}=#{v}" }.join("; ")
  end

  def extract_cookies(response)
    cookies = {}
    response.get_fields("set-cookie")&.each do |cookie_str|
      name, value = cookie_str.split(";").first.split("=", 2)
      cookies[name.strip] = value&.strip
    end
    cookies
  end
end
