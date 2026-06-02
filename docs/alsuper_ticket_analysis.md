# Alsuper — Ticket Analysis for Invoice Flow

## Ticket Data Extracted

### Store
- **Chain:** Alsuper Plus
- **Branch:** La Fuente
- **Address:** Ave. Cuauhtemoc y Calle 22a S/N, Col. Centro, C.P. 31000, Chihuahua, Chih.
- **Tienda #:** 004
- **Punto de Venta:** 01

### Business (Emisor)
- **Razón Social:** Operadora Futurama
- **RFC:** OFU910626UQ0
- **Address:** Paseo de las Facultades 601, Los Huertos, CP 31125, Chih.
- **Régimen Fiscal:** 623

### Transaction
- **Folio:** 1210117
- **Fecha:** 2026-03-27 09:47
- **Barcode:** 2101121011703
- **Cajero:** Jesus Moreno
- **Punto de Venta:** 01

### Items
| Qty | Description          | Unit Price | Total   |
|-----|---------------------|-----------|---------|
| 1   | Barra Zero Hersh    | 24.90     | 24.90N  |
| 1   | Coctel de Alsup     | 31.90     | 31.90N  |
| 1   | Tiras de V Alsup    | 32.90     | 32.90N  |
| 1   | Tums Extra Haleo    | 109.90    | 109.90N |

- **Total Venta:** $199.60 (this is the amount used for invoicing, NOT 200.00)
- **Redondeo:** $0.40 (Nariz Roja A.C. — donation, not part of invoice)
- **Total Pagado:** $200.00
- **IVA:** 0.00
- **IEPS:** 1.84
- **No. Artículos:** 00004

### Payment
- **Method:** Carnet Débito / Visa Débito
- **Card ending:** 0655

### Club Alsuper
- **No.:** 020949173979
- **Nombre:** Rosa Calvillo Solis

## Invoice Platform Analysis

### Platform: rfácil (ASP.NET WebForms)
- **URL:** https://facturacion.alsuper.com/
- **Actual page:** https://facturacion.alsuper.com/Public/IniciaAutoFacturacion.aspx
- **Technology:** ASP.NET WebForms with `__doPostBack` and ViewState
- **Title:** "Portal de Auto Facturación - rfácil"

### Form Fields (all required *)

| Field Label           | ASP.NET Name                                  | HTML ID                                  | Type    | Notes |
|-----------------------|-----------------------------------------------|------------------------------------------|---------|-------|
| Emisor (RFC)          | ClWCAutoFacturaPortal2$txtRFCEmisor           | txtRFCEmisor                             | text    | Pre-filled: OFU910626UQ0. Read-only. |
| Sucursal *            | ClWCAutoFacturaPortal2$cmbSucursal            | cmbSucursal                              | select  | Dropdown with all branch names & IDs. LA FUENTE = value "4" |
| R.F.C. del Cliente *  | ClWCAutoFacturaPortal2$txtRFCReceptor         | txtRFCReceptor                           | text    | 12 or 13 chars |
| Folio *               | ClWCAutoFacturaPortal2$txtIdentificador1      | txtIdentificador1                        | text    | Ticket folio number |
| Punto de Venta *      | ClWCAutoFacturaPortal2$txtIdentificador2      | txtIdentificador2                        | text    | "01" from ticket |
| Fecha de Emisión *    | ClWCAutoFacturaPortal2$txtFechaEmision        | ClWCAutoFacturaPortal2_txtFechaEmision   | text    | Date picker, format TBD |
| Total Venta *         | ClWCAutoFacturaPortal2$txtMontoFactura        | ClWCAutoFacturaPortal2_txtMontoFactura   | text    | Amount (199.60, not 200.00) |
| Correo Electrónico *  | ClWCAutoFacturaPortal2$txtCorreoElectronico   | ClWCAutoFacturaPortal2_txtCorreoElectronico | text | Email for invoice delivery |

### Submit Buttons

| Button               | ASP.NET Name                                  | Type   | Action |
|----------------------|-----------------------------------------------|--------|--------|
| Facturar             | ClWCAutoFacturaPortal2$btnFacturar            | button | __doPostBack → server-side invoice generation |
| Consultar Mis Facturas | ClWCAutoFacturaPortal2$btnMisFacturas       | submit | Look up existing invoices by RFC + email |

### Sucursal Mapping (key branches)

| Branch Name   | Value |
|---------------|-------|
| LA FUENTE     | 4     |
| BAHÍAS        | 46    |
| CAMPUS        | 2     |
| LEONES        | 6     |
| ROBINSON      | 3     |
| VALLARTA      | 7     |
| CENTRO DELICIAS | 17  |
| PARRAL        | 18    |

(Full list has ~90 branches)

### Ticket → Form Field Mapping

| Ticket Field       | Form Field      | Example Value |
|--------------------|-----------------|---------------|
| Sucursal name      | cmbSucursal     | "4" (La Fuente) |
| (user input)       | txtRFCReceptor  | BCO100113TN3  |
| Folio: 1210117     | txtIdentificador1 | 1210117     |
| Punto de Venta: 01 | txtIdentificador2 | 01          |
| 27/03/26 09:47     | txtFechaEmision | TBD format    |
| Total Venta: 199.60| txtMontoFactura | 199.60        |
| (user input)       | txtCorreoElectronico | email    |

### Important Notes

1. **Total Venta vs Total Pagado**: The invoice amount is `199.60` (Total Venta), NOT `200.00` (which includes the charity rounding).
2. **ASP.NET ViewState**: This is a traditional ASP.NET WebForms app. Server-side integration requires:
   - Fetching the page first to get `__VIEWSTATE`, `__VIEWSTATEGENERATOR`, `__EVENTVALIDATION`
   - Submitting the form via POST with all hidden fields + form data
   - Parsing the response HTML for success/error messages
3. **No REST API**: Unlike TimbraXML or US Fuel, this uses ASP.NET postback — there are no clean JSON API endpoints.
4. **Sucursal detection**: The ticket says "Bahias - 4557" but the branch is actually "LA FUENTE" (Tienda #004). Need to map Tienda # to sucursal dropdown value.
5. **Platform name**: "rfácil" — this is a third-party invoicing platform used by multiple businesses.

### Integration Strategy — IMPLEMENTED

Since rfácil uses ASP.NET WebForms (no REST API), the integration approach is:

1. **GET** the form page to obtain `__VIEWSTATE` + `__EVENTVALIDATION` tokens
2. **POST** the form with all required fields + ASP.NET hidden fields via `__doPostBack`
3. **Parse** the HTML response for success/error messages
4. Follow any redirects for PDF/XML download

### Implementation Files

- `app/services/invoice_platform_registry.rb` — Added `:rfacil` platform with field mappings, must be detected BEFORE `:timbraxml`
- `app/services/invoice_form_filler_service.rb` — Added `verify_rfacil`, `rfacil_submit_invoice`, `rfacil_parse_response`, `rfacil_set_ticket_data`, `extract_aspnet_field`, `rfacil_format_fecha`
- `app/controllers/invoices_controller.rb` — Added rfácil-specific handling in `generate_invoice` (simpler validation, sucursal mapping), `datos_fiscales` (passes `@platform_key`)
- `app/views/invoices/datos_fiscales.html.erb` — Hides CFDI fields (razón social, régimen, uso CFDI, código postal) for rfácil since the platform handles those
- `app/services/invoice_url_parser_service.rb` — Updated Gemini prompt to extract `sucursal_value` and `punto_venta` for supermarket tickets

### Key Differences from TimbraXML/US Fuel

1. **Single-step form** — No wizard, no separate verify/preview/confirm steps
2. **ASP.NET ViewState** — Must extract and re-submit hidden tokens with every POST
3. **Simpler user input** — Only RFC + email required from user; rfácil handles CFDI metadata
4. **Platform handles CFDI** — Razón social, régimen fiscal, uso CFDI are resolved by rfácil from SAT
5. **Invoice sent by email** — rfácil emails PDF/XML to the provided address; we may not get files back directly

### Status: Ready for Testing

The integration code is complete but needs real-world testing with a valid ticket. Cannot test from sandbox (blocked by proxy).
