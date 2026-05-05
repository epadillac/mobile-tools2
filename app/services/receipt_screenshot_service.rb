class ReceiptScreenshotService
  # Search for a usable headless Chrome/Chromium binary across macOS dev and Linux
  # production containers. Returns the first one that exists, or nil.
  CHROME_CANDIDATES = [
    ENV["CHROME_BIN"],
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser"
  ].compact.freeze

  def initialize(items:, receipt_total:, restaurant_name:)
    @items = items
    @receipt_total = receipt_total
    @restaurant_name = restaurant_name
  end

  def capture
    chrome = chrome_path
    unless chrome
      Rails.logger.info("ReceiptScreenshotService: no Chrome binary found, skipping screenshot")
      return nil
    end

    html_file = generate_html
    screenshot_path = Rails.root.join("tmp", "screenshot_#{SecureRandom.hex(8)}.png").to_s

    success = system(
      chrome,
      "--headless",
      "--disable-gpu",
      "--no-sandbox",
      "--screenshot=#{screenshot_path}",
      "--window-size=500,900",
      "--hide-scrollbars",
      "file://#{html_file.path}",
      out: File::NULL,
      err: File::NULL
    )

    html_file.close
    html_file.unlink

    if success && File.exist?(screenshot_path)
      Rails.logger.info("ReceiptScreenshotService: Screenshot captured at #{screenshot_path}")
      screenshot_path
    else
      Rails.logger.error("ReceiptScreenshotService: Chrome screenshot failed")
      nil
    end
  rescue StandardError => e
    Rails.logger.error("ReceiptScreenshotService error: #{e.message}")
    nil
  end

  private

  def chrome_path
    CHROME_CANDIDATES.find { |path| File.executable?(path) }
  end

  def generate_html
    subtotal = @items.sum { |i| i[:price].to_f }
    difference = @receipt_total && @receipt_total > 0 ? (@receipt_total - subtotal).abs : 0
    has_difference = difference >= 1.0

    items_html = @items.map do |item|
      if item[:is_modifier]
        <<~HTML
          <div class="item modifier">
            <span>+ #{h(item[:name])}</span>
            <span>$#{'%.2f' % item[:price]}</span>
          </div>
        HTML
      else
        <<~HTML
          <div class="item">
            <span class="bold">#{h(item[:name])}</span>
            <span class="bold">$#{'%.2f' % item[:price]}</span>
          </div>
        HTML
      end
    end.join

    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f3f4f6; padding: 16px; }

          .card { background: white; border-radius: 12px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); margin-bottom: 16px; overflow: hidden; }

          .diferencia-card { padding: 20px; }
          .diferencia-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
          .diferencia-header h2 { font-size: 16px; color: #1f2937; }
          .badge { padding: 4px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; }
          .badge-warning { background: #fef3c7; color: #92400e; }
          .badge-ok { background: #d1fae5; color: #065f46; }
          .totals-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
          .total-box { padding: 12px; border-radius: 8px; }
          .total-box.gray { background: #f9fafb; }
          .total-box.blue { background: #eef2ff; }
          .total-label { font-size: 11px; color: #6b7280; margin-bottom: 4px; }
          .total-value { font-size: 22px; font-weight: 700; }
          .total-value.blue { color: #4f46e5; }

          .receipt { font-family: 'Courier New', monospace; }
          .receipt-header { text-align: center; padding: 12px; border-bottom: 1px dashed #d1d5db; font-size: 12px; color: #6b7280; letter-spacing: 2px; }
          .items { padding: 8px 16px; }
          .item { display: flex; justify-content: space-between; padding: 4px 0; font-size: 13px; color: #374151; }
          .item.modifier { padding-left: 12px; color: #9ca3af; font-size: 12px; }
          .bold { font-weight: 600; }
          .separator { border-top: 1px dashed #d1d5db; margin: 0 16px; }
          .total-row { display: flex; justify-content: space-between; padding: 12px 16px; font-size: 16px; font-weight: 700; color: #111827; }
        </style>
      </head>
      <body>
        #{has_difference ? diferencia_html(difference) : ok_html}

        <div class="card receipt">
          <div class="receipt-header">*** #{h(@restaurant_name.presence || 'TICKET')} ***</div>
          <div class="items">#{items_html}</div>
          <div class="separator"></div>
          <div class="total-row">
            <span>TOTAL</span>
            <span>$#{'%.2f' % subtotal}</span>
          </div>
        </div>
      </body>
      </html>
    HTML

    file = Tempfile.new(["receipt", ".html"])
    file.write(html)
    file.flush
    file
  end

  def diferencia_html(difference)
    subtotal = @items.sum { |i| i[:price].to_f }
    <<~HTML
      <div class="card diferencia-card">
        <div class="diferencia-header">
          <h2>Verificacion de Totales</h2>
          <span class="badge badge-warning">Diferencia: $#{'%.2f' % difference}</span>
        </div>
        <div class="totals-grid">
          <div class="total-box gray">
            <div class="total-label">Total del Ticket (imagen)</div>
            <div class="total-value">$#{'%.2f' % @receipt_total}</div>
          </div>
          <div class="total-box blue">
            <div class="total-label">Total de Articulos (procesados)</div>
            <div class="total-value blue">$#{'%.2f' % subtotal}</div>
          </div>
        </div>
      </div>
    HTML
  end

  def ok_html
    subtotal = @items.sum { |i| i[:price].to_f }
    <<~HTML
      <div class="card diferencia-card">
        <div class="diferencia-header">
          <h2>Verificacion de Totales</h2>
          <span class="badge badge-ok">✓ Totales coinciden</span>
        </div>
        <div class="totals-grid">
          <div class="total-box gray">
            <div class="total-label">Total del Ticket (imagen)</div>
            <div class="total-value">$#{'%.2f' % (@receipt_total || subtotal)}</div>
          </div>
          <div class="total-box blue">
            <div class="total-label">Total de Articulos (procesados)</div>
            <div class="total-value blue">$#{'%.2f' % subtotal}</div>
          </div>
        </div>
      </div>
    HTML
  end

  def h(text)
    ERB::Util.html_escape(text.to_s)
  end
end
