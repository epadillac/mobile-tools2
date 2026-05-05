# Registry of known invoice platforms and their form field mappings.
# Each platform entry defines how to auto-fill the invoice form on the website.
#
# To add a new restaurant/platform:
# 1. Visit the restaurant's invoice URL
# 2. Inspect the form fields (name/id attributes)
# 3. Add a new entry to PLATFORMS with the field mappings
# 4. The auto-fill JS will be generated automatically
#
# IMPORTANT: Platform detection order matters!
# More specific platforms (like usfuel) must come BEFORE generic ones (like timbraxml)
# because both can match "facturacion." in the URL.
#
class InvoicePlatformRegistry
  # SAT RFC validation regex (CFDI 4.0)
  # Covers persona física (13 chars) and persona moral (12 chars)
  RFC_REGEX = /\A[A-Z&Ñ]{3,4}[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[A-Z0-9]{2}[0-9A]\z/

  # Persona moral (company) - 12 chars
  RFC_MORAL_REGEX = /\A[A-ZÑ&]{3}[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[A-Z0-9]{3}\z/

  # Persona física (individual) - 13 chars
  RFC_FISICA_REGEX = /\A[A-ZÑ&]{4}[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[A-Z0-9]{3}\z/

  # Generic RFC for público en general
  RFC_GENERICO = "XAXX010101000"

  # Validates RFC format per SAT standards
  def self.valid_rfc?(rfc)
    return false if rfc.blank?
    rfc = rfc.to_s.strip.upcase
    rfc.match?(RFC_REGEX)
  end

  # Returns RFC type: :moral, :fisica, :generico, or nil
  def self.rfc_type(rfc)
    return nil if rfc.blank?
    rfc = rfc.to_s.strip.upcase
    return :generico if rfc == RFC_GENERICO
    return :moral if rfc.match?(RFC_MORAL_REGEX)
    return :fisica if rfc.match?(RFC_FISICA_REGEX)
    nil
  end

  # Standard SAT Uso CFDI options (CFDI 4.0)
  USO_CFDI_OPTIONS = [
    { value: "G01", label: "G01 - Adquisición de mercancías" },
    { value: "G02", label: "G02 - Devoluciones, descuentos o bonificaciones" },
    { value: "G03", label: "G03 - Gastos en general" },
    { value: "I01", label: "I01 - Construcciones" },
    { value: "I02", label: "I02 - Mobiliario y equipo de oficina por inversiones" },
    { value: "I03", label: "I03 - Equipo de transporte" },
    { value: "I04", label: "I04 - Equipo de cómputo y accesorios" },
    { value: "I05", label: "I05 - Dados, troqueles, moldes, matrices y herramental" },
    { value: "I06", label: "I06 - Comunicaciones telefónicas" },
    { value: "I07", label: "I07 - Comunicaciones satelitales" },
    { value: "I08", label: "I08 - Otra maquinaria y equipo" },
    { value: "D01", label: "D01 - Honorarios médicos, dentales y gastos hospitalarios" },
    { value: "D02", label: "D02 - Gastos médicos por incapacidad o discapacidad" },
    { value: "D03", label: "D03 - Gastos funerales" },
    { value: "D04", label: "D04 - Donativos" },
    { value: "D05", label: "D05 - Intereses reales pagados por créditos hipotecarios" },
    { value: "D06", label: "D06 - Aportaciones voluntarias al SAR" },
    { value: "D07", label: "D07 - Primas por seguros de gastos médicos" },
    { value: "D08", label: "D08 - Gastos de transportación escolar obligatoria" },
    { value: "D09", label: "D09 - Depósitos en cuentas para el ahorro" },
    { value: "D10", label: "D10 - Pagos por servicios educativos (colegiaturas)" },
    { value: "S01", label: "S01 - Sin efectos fiscales" },
    { value: "CP01", label: "CP01 - Pagos" },
    { value: "CN01", label: "CN01 - Nómina" }
  ].freeze

  # Standard SAT Régimen Fiscal options (CFDI 4.0)
  REGIMEN_FISCAL_OPTIONS = [
    { value: "601", label: "601 - General de Ley Personas Morales" },
    { value: "603", label: "603 - Personas Morales con Fines no Lucrativos" },
    { value: "605", label: "605 - Sueldos y Salarios e Ingresos Asimilados a Salarios" },
    { value: "606", label: "606 - Arrendamiento" },
    { value: "607", label: "607 - Régimen de Enajenación o Adquisición de Bienes" },
    { value: "608", label: "608 - Demás ingresos" },
    { value: "610", label: "610 - Residentes en el Extranjero sin Establecimiento Permanente en México" },
    { value: "611", label: "611 - Ingresos por Dividendos (socios y accionistas)" },
    { value: "612", label: "612 - Personas Físicas con Actividades Empresariales y Profesionales" },
    { value: "614", label: "614 - Ingresos por intereses" },
    { value: "615", label: "615 - Régimen de los ingresos por obtención de premios" },
    { value: "616", label: "616 - Sin obligaciones fiscales" },
    { value: "620", label: "620 - Sociedades Cooperativas de Producción que optan por diferir sus ingresos" },
    { value: "621", label: "621 - Incorporación Fiscal" },
    { value: "622", label: "622 - Actividades Agrícolas, Ganaderas, Silvícolas y Pesqueras" },
    { value: "623", label: "623 - Opcional para Grupos de Sociedades" },
    { value: "624", label: "624 - Coordinados" },
    { value: "625", label: "625 - Régimen de las Actividades Empresariales con ingresos a través de Plataformas Tecnológicas" },
    { value: "626", label: "626 - Régimen Simplificado de Confianza" }
  ].freeze

  # Standard SAT Forma de Pago options
  FORMA_PAGO_OPTIONS = [
    { value: "01", label: "Efectivo" },
    { value: "02", label: "Cheque nominativo" },
    { value: "03", label: "Transferencia electrónica de fondos" },
    { value: "04", label: "Tarjeta de crédito" },
    { value: "05", label: "Monedero electrónico" },
    { value: "06", label: "Dinero electrónico" },
    { value: "28", label: "Tarjeta de débito" },
    { value: "29", label: "Tarjeta de servicios" },
    { value: "99", label: "Por definir" }
  ].freeze

  # Each platform has:
  #   name:        Human-readable platform name
  #   detect:      Lambda that checks if a URL belongs to this platform
  #   fields:      Hash mapping our data keys to the form's input name/id attributes
  #   wizard:      Whether the form uses a multi-step wizard (needs "next" click)
  #   next_button: CSS selector for the "next" button in the wizard
  #   api_base:    Base URL for server-side API calls (if different from invoice URL)
  #   needs_rfc_step1: Whether RFC is required in step 1 (ticket verification)
  #   needs_forma_pago: Whether forma de pago is required
  #   notes:       Any special instructions for this platform
  #
  PLATFORMS = {
    # =====================================================================
    # rfácil — ASP.NET WebForms invoice platform
    # Used by: Alsuper Plus, and other businesses using rfácil
    # Form: Single-page ASP.NET postback (ViewState + EventValidation)
    # IMPORTANT: Must be detected BEFORE timbraxml (both have "facturacion." URLs)
    # =====================================================================
    rfacil: {
      name: "rfácil",
      detect: ->(url) {
        url.include?("alsuper.com") || url.include?("rfacil.com")
      },
      fields: {
        rfc_emisor:    { selector: "#txtRFCEmisor",      name: "ClWCAutoFacturaPortal2$txtRFCEmisor" },
        sucursal:      { selector: "#cmbSucursal",        name: "ClWCAutoFacturaPortal2$cmbSucursal" },
        rfc_receptor:  { selector: "#txtRFCReceptor",     name: "ClWCAutoFacturaPortal2$txtRFCReceptor" },
        folio:         { selector: "#txtIdentificador1",  name: "ClWCAutoFacturaPortal2$txtIdentificador1" },
        punto_venta:   { selector: "#txtIdentificador2",  name: "ClWCAutoFacturaPortal2$txtIdentificador2" },
        fecha:         { selector: "#ClWCAutoFacturaPortal2_txtFechaEmision",  name: "ClWCAutoFacturaPortal2$txtFechaEmision" },
        importe:       { selector: "#ClWCAutoFacturaPortal2_txtMontoFactura",  name: "ClWCAutoFacturaPortal2$txtMontoFactura" },
        email:         { selector: "#ClWCAutoFacturaPortal2_txtCorreoElectronico", name: "ClWCAutoFacturaPortal2$txtCorreoElectronico" }
      },
      submit_button: "ClWCAutoFacturaPortal2$btnFacturar",
      form_path: "/Public/IniciaAutoFacturacion.aspx",
      wizard: false,
      next_button: nil,
      needs_rfc_step1: false,
      needs_forma_pago: false,
      aspnet_webforms: true,
      notes: "ASP.NET WebForms app. Requires GET to obtain ViewState/EventValidation tokens before POST. " \
             "Ticket data maps: folio → Identificador1, punto_venta → Identificador2, importe → Total Venta (NOT total pagado). " \
             "Sucursal is a dropdown — must match Tienda # from ticket to dropdown value."
    },

    # =====================================================================
    # US Fuel / Rendilitros — Gas station invoice platform
    # Used by: US Fuel / PRONTOGAS
    # Backend API: addesapi.rendilitros.com
    # Form: 4-step AngularJS wizard (Ticket+RFC → Datos Fiscales → Confirmar → Descargar)
    # IMPORTANT: Must be detected BEFORE timbraxml (both have "facturacion." URLs)
    # =====================================================================
    usfuel: {
      name: "US Fuel / Rendilitros",
      detect: ->(url) {
        url.include?("usfuel.com") || url.include?("rendilitros.com")
      },
      fields: {
        ticket:      { selector: 'input[ng-model="datosTicket.txtTicket"]',       name: "txtTicket" },
        fecha:       { selector: 'input[ng-model="datosTicket.txtFechaTicket"]',  name: "txtFechaTicket" },
        importe:     { selector: 'input[ng-model="datosTicket.txtImporte"]',      name: "txtImporte" },
        rfc:         { selector: 'input[ng-model="datosTicket.txtRfcCliente"]',   name: "txtRfcCliente" },
        forma_pago:  { selector: 'select[ng-model="datosTicket.cmbFormaPago"]',   name: "cmbFormaPago" }
      },
      api_base: "https://addesapi.rendilitros.com",
      api_endpoints: {
        verify_ticket: "/api/Despacho/GetTicketWEB",
        get_station:   "/api/Estacion/GetEstacion",
        get_client:    "/api/Cliente/GetClienteByRFC",
        set_client:    "/api/Cliente/SetCliente",
        update_client: "/api/Cliente/SetClienteUpd",
        set_email:     "/api/Cliente/SetClienteCorreo",
        get_uso_cfdi:  "/api/Catalogos/GetUsosCFDI",
        timbrar:       "/api/CFDI/Timbrar"
      },
      wizard: true,
      next_button: 'button:contains("Siguiente")',
      needs_rfc_step1: true,
      needs_forma_pago: true,
      notes: "RFC is required in step 1. Ticket must wait 1hr after purchase to be invoiced. Backend API at addesapi.rendilitros.com."
    },

    # =====================================================================
    # TimbraXML — Most common Mexican restaurant invoice platform
    # Used by: Hakuna Bolas de Arroz, and many others
    # Form: 4-step wizard (Datos Ticket → Datos Personales → Vista Previa → Facturar)
    # =====================================================================
    timbraxml: {
      name: "TimbraXML",
      detect: ->(url) {
        # TimbraXML sites typically use facturacion.{domain} or autofacturacion.{domain}
        url.include?("facturacion.") || url.include?("autofacturacion.")
      },
      fields: {
        serie:   { selector: "#tienda",       name: "tienda" },
        folio:   { selector: "#ticket",        name: "ticket" },
        importe: { selector: "#importe",       name: "importe" },
        fecha:   { selector: "#fecha_ticket",  name: "fecha_ticket" }
      },
      api_endpoints: {
        verify_ticket:    "/facturacion/verificaParametros",
        get_rfc:          "/facturacion/getRFC",
        get_select:       "/facturacion/getSelect",
        generate_preview: "/facturacion/generarVistaPrevia",
        confirm_invoice:  "/facturacion/verificaFactura",
        download_docs:    "/facturacion/documentos"
      },
      wizard: true,
      next_button: 'a[href="#next"]',
      needs_rfc_step1: false,
      needs_forma_pago: false,
      notes: "Serie must be 6 letters only (no numbers). Folio is numeric."
    },

    # =====================================================================
    # MeFacturo — Another common platform
    # Used by: La Cabaña Smokehouse, and others
    # URL pattern: mefacturo.mx/{business_code}
    # =====================================================================
    mefacturo: {
      name: "MeFacturo",
      detect: ->(url) { url.include?("mefacturo.mx") },
      fields: {
        folio:   { selector: 'input[name="folio"]',   name: "folio" },
        importe: { selector: 'input[name="total"]',    name: "total" },
        fecha:   { selector: 'input[name="fecha"]',    name: "fecha" },
        rfc:     { selector: 'input[name="rfc"]',      name: "rfc" }
      },
      wizard: false,
      next_button: nil,
      needs_rfc_step1: false,
      needs_forma_pago: false,
      notes: "May require scanning QR code for some businesses."
    }
  }.freeze

  # Detect which platform a URL belongs to
  def self.detect(url)
    return nil unless url.present?

    PLATFORMS.each do |key, config|
      return key if config[:detect].call(url)
    end

    nil # Unknown platform
  end

  # Get the platform configuration
  def self.config_for(platform_key)
    PLATFORMS[platform_key&.to_sym]
  end

  # Get the platform configuration by URL
  def self.config_for_url(url)
    key = detect(url)
    key ? PLATFORMS[key] : nil
  end

  # Check if a platform requires RFC in step 1
  def self.needs_rfc_step1?(platform_key)
    config_for(platform_key)&.dig(:needs_rfc_step1) || false
  end

  # Check if a platform requires forma de pago
  def self.needs_forma_pago?(platform_key)
    config_for(platform_key)&.dig(:needs_forma_pago) || false
  end

  # Generate JavaScript code to auto-fill the form on the invoice website.
  # This JS is designed to be injected via a bookmarklet or pasted in the console.
  def self.autofill_js(platform_key, data)
    config = config_for(platform_key)
    return nil unless config

    field_assignments = config[:fields].map do |data_key, field_info|
      value = data[data_key]
      next nil unless value.present?

      value_str = value.to_s.gsub("'", "\\\\'")
      <<~JS.strip
        el = document.querySelector('#{field_info[:selector]}') || document.querySelector('[name="#{field_info[:name]}"]');
        if (el) { el.value = '#{value_str}'; el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); filled++; }
      JS
    end.compact.join("\n  ")

    <<~JS
      (function() {
        var el, filled = 0;
        #{field_assignments}
        if (filled > 0) {
          alert('Se llenaron ' + filled + ' campos automaticamente.');
        } else {
          alert('No se encontraron campos para llenar. Estas en la pagina correcta?');
        }
      })();
    JS
  end

  # Generate a bookmarklet URL (javascript: protocol) for auto-fill
  def self.bookmarklet_url(platform_key, data)
    js = autofill_js(platform_key, data)
    return nil unless js
    "javascript:#{ERB::Util.url_encode(js.gsub(/\n\s*/, ' ').strip)}"
  end

  # List all known platforms (for admin/debug)
  def self.all_platforms
    PLATFORMS.map { |key, config| { key: key, name: config[:name], notes: config[:notes] } }
  end
end
