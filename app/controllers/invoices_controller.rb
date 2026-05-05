class InvoicesController < ApplicationController
  layout "split_checks"
  skip_forgery_protection if: -> { hotwire_native_app? || via_tunnel? }

  def new
  end

  def create
    @receipt_image = params[:receipt_image]

    unless @receipt_image.present?
      flash.now[:alert] = "Por favor sube una imagen del ticket."
      render :new, status: :unprocessable_entity
      return
    end

    image_path = @receipt_image.tempfile.path
    content_type = @receipt_image.content_type || "image/jpeg"

    service = InvoiceUrlParserService.new(image_path, content_type)
    result = service.parse

    if service.rate_limited?
      flash.now[:alert] = "Servicio ocupado. Espera un momento e intenta de nuevo."
      render :new, status: :too_many_requests
    elsif result[:invoice_url].blank? && result[:invoice_data].empty?
      flash.now[:alert] = "No se encontró información de facturación en este ticket. Intenta con una imagen más clara."
      render :new, status: :unprocessable_entity
    else
      # Detect platform (store only the key, not generated JS)
      platform_key = InvoicePlatformRegistry.detect(result[:invoice_url])
      result[:platform] = platform_key&.to_s
      result[:platform_name] = InvoicePlatformRegistry.config_for(platform_key)&.dig(:name)

      session[:invoice_result] = result
      redirect_to invoice_path(id: "current")
    end
  end

  def show
    if session[:invoice_result].present?
      @result = session[:invoice_result].deep_symbolize_keys
    else
      redirect_to new_invoice_path and return
    end
  end

  # POST /invoices/:id/verify
  # Validates ticket data against the invoice platform server-side.
  # Called via AJAX from the show page. Receives RFC (required) and forma_pago (optional).
  def verify
    result = session[:invoice_result]&.deep_symbolize_keys
    unless result&.dig(:invoice_url).present? && result&.dig(:invoice_data).present?
      render json: { success: false, error: "No hay datos de facturación en la sesión." }, status: :unprocessable_entity
      return
    end

    # Validate RFC using SAT regex
    rfc = (params[:rfc] || request.raw_post&.then { |b| JSON.parse(b)["rfc"] rescue nil }).to_s.strip.upcase
    unless InvoicePlatformRegistry.valid_rfc?(rfc)
      render json: { success: false, error: "El RFC no tiene un formato válido según el SAT." }
      return
    end

    # Store RFC and forma_pago in the session for subsequent steps
    forma_pago = (params[:forma_pago] || request.raw_post&.then { |b| JSON.parse(b)["forma_pago"] rescue nil }).to_s.strip
    session[:invoice_rfc] = rfc
    session[:invoice_forma_pago] = forma_pago if forma_pago.present?

    data = result[:invoice_data]
    filler = InvoiceFormFillerService.new(result[:invoice_url])

    verification = filler.verify_ticket(
      serie:   data[:serie].to_s,
      folio:   data[:folio].to_s,
      importe: data[:importe].to_s,
      fecha:   data[:fecha].to_s
    )

    # Store cookies from verification for subsequent requests
    if verification[:success]
      session[:invoice_cookies] = filler.cookies
    end

    # For US Fuel: if ticket is already invoiced, let it pass through to datos_fiscales
    # so that generate_invoice can attempt to recover the existing invoice files.
    platform_key = InvoicePlatformRegistry.detect(result[:invoice_url])
    if !verification[:success] && platform_key == :usfuel && verification[:error].to_s.downcase.include?("facturado")
      session[:invoice_cookies] = filler.cookies
      session[:invoice_already_invoiced_hint] = true
      render json: { success: true, already_invoiced: true }
      return
    end

    render json: verification
  end

  # GET /invoices/:id/datos_fiscales
  # Shows the personal data form (RFC, uso CFDI, email) for step 2.
  def datos_fiscales
    result = session[:invoice_result]&.deep_symbolize_keys
    unless result&.dig(:invoice_url).present?
      redirect_to new_invoice_path and return
    end

    @result = result
    @invoice_data = result[:invoice_data] || {}
    @rfc = session[:invoice_rfc] || @invoice_data[:rfc].to_s
    @forma_pago = session[:invoice_forma_pago]
    @platform_key = InvoicePlatformRegistry.detect(result[:invoice_url])
  end

  # POST /invoices/:id/lookup_rfc
  # AJAX: Validates RFC and returns razón social + dropdown options
  def lookup_rfc
    result = session[:invoice_result]&.deep_symbolize_keys
    unless result&.dig(:invoice_url).present?
      render json: { success: false, error: "No hay datos en la sesión." }, status: :unprocessable_entity
      return
    end

    body_params = begin
      JSON.parse(request.raw_post)
    rescue
      params.to_unsafe_h
    end
    rfc = (body_params["rfc"] || params[:rfc]).to_s.strip.upcase
    unless InvoicePlatformRegistry.valid_rfc?(rfc)
      render json: { success: false, error: "El RFC no tiene un formato válido según el SAT." }
      return
    end

    cookies = session[:invoice_cookies] || {}
    filler = InvoiceFormFillerService.new(result[:invoice_url], cookies: cookies)

    # Lookup RFC data
    rfc_result = filler.lookup_rfc(rfc)

    # Get dropdown options
    select_result = filler.get_select_options(rfc)

    # Update stored cookies
    session[:invoice_cookies] = filler.cookies

    if rfc_result[:success]
      render json: {
        success: true,
        data: rfc_result[:data] || {},
        regimen_options: select_result[:regimen_options] || select_result[:options] || [],
        uso_cfdi_options: select_result[:uso_cfdi_options] || []
      }
    else
      render json: rfc_result
    end
  end

  # POST /invoices/:id/generate_invoice
  # Executes the full invoice generation flow: preview → confirm → done
  def generate_invoice
    result = session[:invoice_result]&.deep_symbolize_keys
    unless result&.dig(:invoice_url).present? && result&.dig(:invoice_data).present?
      render json: { success: false, error: "No hay datos de facturación en la sesión." }, status: :unprocessable_entity
      return
    end

    data = result[:invoice_data]
    cookies = session[:invoice_cookies] || {}
    filler = InvoiceFormFillerService.new(result[:invoice_url], cookies: cookies)

    # Parse JSON body params
    body_params = begin
      JSON.parse(request.raw_post)
    rescue
      params.to_unsafe_h
    end

    rfc            = (body_params["rfc"] || session[:invoice_rfc]).to_s.strip.upcase
    uso_cfdi       = body_params["uso_cfdi"].to_s.strip
    email          = body_params["email"].to_s.strip
    razon_social   = body_params["razon_social"].to_s.strip
    regimen        = body_params["regimen"].to_s.strip
    codigo_postal  = body_params["codigo_postal"].to_s.strip
    forma_pago     = (body_params["forma_pago"] || session[:invoice_forma_pago] || "99").to_s.strip

    platform_key = InvoicePlatformRegistry.detect(result[:invoice_url])

    # Validate required fields — rfácil only needs RFC + email (the platform handles CFDI details)
    missing = []
    missing << "RFC" if rfc.blank?
    missing << "Correo electrónico" if email.blank?
    unless platform_key == :rfacil
      missing << "Razón Social" if razon_social.blank?
      missing << "Uso de CFDI" if uso_cfdi.blank?
      missing << "Régimen Fiscal" if regimen.blank?
      missing << "Código Postal" if codigo_postal.blank? || codigo_postal.length != 5
    end
    if missing.any?
      render json: { success: false, error: "Campos obligatorios faltantes: #{missing.join(', ')}" }
      return
    end

    # For rfácil: set ticket-specific data on the filler (sucursal, punto de venta)
    if platform_key == :rfacil
      # sucursal_value is the store number (e.g., "004" → "4" for dropdown)
      raw_sucursal = (data[:sucursal_value] || data[:serie]).to_s.gsub(/\A0+/, "")
      sucursal_value = raw_sucursal.present? ? raw_sucursal : ""
      punto_venta = data[:punto_venta].present? ? data[:punto_venta].to_s : "01"
      rfc_emisor = data[:rfc]
      filler.rfacil_set_ticket_data(
        sucursal_value: sucursal_value,
        punto_venta: punto_venta,
        rfc_emisor: rfc_emisor
      )
    end

    serie   = data[:serie].to_s
    folio   = data[:folio].to_s
    importe = data[:importe].to_s
    fecha   = data[:fecha].to_s

    # Step 1: Re-verify ticket (ensures session is valid on the platform)
    verify_result = filler.verify_ticket(serie: serie, folio: folio, importe: importe, fecha: fecha)
    unless verify_result[:success]
      # For US Fuel: if ticket is already invoiced, try to recover the existing invoice files
      if platform_key == :usfuel && verify_result[:error].to_s.downcase.include?("facturado")
        recover_result = filler.recover_existing_invoice(folio: folio, rfc: rfc, fecha: fecha)
        if recover_result[:success]
          # Save recovered files and redirect to download page
          save_invoice_files(rfc: rfc, email: email, pdf_base64: recover_result[:pdf_base64], xml_string: recover_result[:xml_string])
          session[:invoice_already_invoiced] = true
          render json: {
            success: true,
            already_invoiced: true,
            message: "Este ticket ya fue facturado. Se recuperaron los archivos de la factura existente.",
            has_pdf: recover_result[:pdf_base64].present?,
            has_xml: recover_result[:xml_string].present?,
            download_url: factura_lista_invoice_path(id: "current")
          }
          return
        else
          render json: { success: false, error: recover_result[:error], step: "verify" }
          return
        end
      end

      render json: { success: false, error: verify_result[:error] || "Error al verificar el ticket.", step: "verify" }
      return
    end

    # For US Fuel: capture ticket data and get station data (needed for Timbrar)
    ticket_data = verify_result[:ticket_data] || {}
    estacion_data = {}
    id_cliente = 0

    if platform_key == :usfuel
      # Get station data
      estacion_result = filler.usfuel_get_estacion(folio)
      estacion_data = estacion_result[:estacion_data] || {} if estacion_result[:success]

      # Get client data (includes IdCliente needed for Timbrar)
      client_result = filler.usfuel_get_client(rfc)
      if client_result[:success] && client_result[:data]
        id_cliente = client_result[:data][:id_cliente].to_i
      end
    end

    # Step 2: Generate preview
    preview_result = filler.generate_preview(
      serie: serie, folio: folio, importe: importe, fecha: fecha,
      rfc: rfc, uso_cfdi: uso_cfdi
    )
    unless preview_result[:success]
      render json: { success: false, error: preview_result[:error] || "Error al generar la vista previa.", step: "preview" }
      return
    end

    # Step 3: Confirm invoice (stamp CFDI)
    confirm_result = filler.confirm_invoice(
      serie: serie, folio: folio, importe: importe, fecha: fecha,
      email: email, rfc: rfc, uso_cfdi: uso_cfdi, forma_pago: forma_pago,
      razon_social: razon_social, regimen: regimen, codigo_postal: codigo_postal,
      ticket_data: ticket_data, estacion_data: estacion_data, id_cliente: id_cliente
    )
    unless confirm_result[:success]
      render json: { success: false, error: confirm_result[:error] || "Error al generar la factura.", step: "confirm" }
      return
    end

    # Update stored cookies
    session[:invoice_cookies] = filler.cookies

    # For rfácil: the platform generates and emails the invoice directly.
    # We may get PDF/XML URLs instead of base64 data, or nothing at all.
    if platform_key == :rfacil
      # rfácil sends the invoice to the provided email — also try to fetch PDF/XML
      session[:invoice_already_invoiced] = false
      session[:invoice_rfc_used] = rfc
      session[:invoice_email_used] = email

      # If rfácil returned direct download URLs, fetch them
      if confirm_result[:pdf_url].present? || confirm_result[:xml_url].present?
        rfacil_download_files(filler, rfc, email, confirm_result[:pdf_url], confirm_result[:xml_url])
      end

      # Try "Consultar Mis Facturas" to find and download the generated invoice files
      if session[:invoice_pdf_path].blank?
        Rails.logger.info("InvoicesController: Attempting rfácil Mis Facturas lookup for PDF/XML")
        mis_facturas = filler.fetch_mis_facturas(rfc: rfc, email: email)
        if mis_facturas[:success] && mis_facturas[:pdf_urls]&.any?
          rfacil_download_files(filler, rfc, email, mis_facturas[:pdf_urls].first, mis_facturas[:xml_urls]&.first)
        end
      end

      render json: {
        success: true,
        message: confirm_result[:message] || "Factura generada. Se enviará a #{email}.",
        has_pdf: session[:invoice_pdf_path].present?,
        has_xml: session[:invoice_xml_path].present?,
        download_url: factura_lista_invoice_path(id: "current")
      }
    else
      # Save PDF and XML files from timbrado response
      save_invoice_files(rfc: rfc, email: email, pdf_base64: confirm_result[:pdf_base64], xml_string: confirm_result[:xml_string])
      session[:invoice_already_invoiced] = false

      render json: {
        success: true,
        message: "Factura generada exitosamente.",
        has_pdf: session[:invoice_pdf_path].present?,
        has_xml: session[:invoice_xml_path].present?,
        download_url: factura_lista_invoice_path(id: "current")
      }
    end
  end

  # GET /invoices/:id/factura_lista
  # Success page showing download links for generated invoice files.
  def factura_lista
    @result = session[:invoice_result]&.deep_symbolize_keys
    unless @result&.dig(:invoice_url).present?
      redirect_to new_invoice_path and return
    end

    @invoice_data = @result[:invoice_data] || {}
    @rfc = session[:invoice_rfc_used]
    @email = session[:invoice_email_used]
    @has_pdf = session[:invoice_pdf_path].present?
    @has_xml = session[:invoice_xml_path].present?
    @already_invoiced = session[:invoice_already_invoiced] == true
  end

  # GET /invoices/:id/download_pdf
  def download_pdf
    path = session[:invoice_pdf_path]
    if path.present? && File.exist?(path)
      rfc = session[:invoice_rfc_used] || "factura"
      send_file path, filename: "Factura_#{rfc}.pdf", type: "application/pdf", disposition: "attachment"
    else
      redirect_to datos_fiscales_invoice_path(id: "current"), alert: "El archivo PDF no está disponible."
    end
  end

  # GET /invoices/:id/download_xml
  def download_xml
    path = session[:invoice_xml_path]
    if path.present? && File.exist?(path)
      rfc = session[:invoice_rfc_used] || "factura"
      send_file path, filename: "Factura_#{rfc}.xml", type: "application/xml", disposition: "attachment"
    else
      redirect_to datos_fiscales_invoice_path(id: "current"), alert: "El archivo XML no está disponible."
    end
  end

  private

  # Saves PDF and XML invoice files to tmp/invoices/ and stores paths in session.
  # Used both for newly timbrado invoices and recovered existing ones.
  def save_invoice_files(rfc:, email:, pdf_base64:, xml_string:)
    pdf_path = nil
    xml_path = nil
    invoice_dir = Rails.root.join("tmp", "invoices")
    FileUtils.mkdir_p(invoice_dir)
    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    safe_rfc = rfc.to_s.gsub(/[^A-Z0-9]/i, "")

    if pdf_base64.present?
      pdf_path = invoice_dir.join("#{safe_rfc}_#{timestamp}.pdf")
      File.binwrite(pdf_path, Base64.decode64(pdf_base64))
      Rails.logger.info("InvoiceController: Saved PDF to #{pdf_path}")
    end

    if xml_string.present?
      xml_path = invoice_dir.join("#{safe_rfc}_#{timestamp}.xml")
      File.write(xml_path, xml_string)
      Rails.logger.info("InvoiceController: Saved XML to #{xml_path}")
    end

    session[:invoice_pdf_path] = pdf_path&.to_s
    session[:invoice_xml_path] = xml_path&.to_s
    session[:invoice_rfc_used] = rfc
    session[:invoice_email_used] = email
  end

  # Downloads PDF/XML files from rfácil URLs and saves them locally.
  def rfacil_download_files(filler, rfc, email, pdf_url, xml_url)
    invoice_dir = Rails.root.join("tmp", "invoices")
    FileUtils.mkdir_p(invoice_dir)
    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    safe_rfc = rfc.to_s.gsub(/[^A-Z0-9]/i, "")

    [
      [pdf_url, "pdf", "application/pdf"],
      [xml_url, "xml", "application/xml"]
    ].each do |url, ext, _content_type|
      next if url.blank?
      begin
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.read_timeout = 15
        req = Net::HTTP::Get.new(uri.request_uri)
        req["Cookie"] = filler.cookies.map { |k, v| "#{k}=#{v}" }.join("; ") if filler.cookies.any?
        response = http.request(req)
        if response.code.to_i == 200 && response.body.present?
          path = invoice_dir.join("#{safe_rfc}_#{timestamp}.#{ext}")
          File.binwrite(path, response.body)
          session[:"invoice_#{ext}_path"] = path.to_s
          Rails.logger.info("InvoicesController: Downloaded rfácil #{ext.upcase} to #{path}")
        end
      rescue => e
        Rails.logger.warn("InvoicesController: Failed to download rfácil #{ext}: #{e.message}")
      end
    end
    session[:invoice_rfc_used] = rfc
    session[:invoice_email_used] = email
  end

  def via_tunnel?
    host = request.host.to_s
    host.include?("ngrok") || host.include?("trycloudflare")
  end
end
