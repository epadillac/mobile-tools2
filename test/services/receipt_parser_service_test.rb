require "test_helper"

class ReceiptParserServiceTest < ActiveSupport::TestCase
  # Expected data for encanto-1.jpeg (Encanto Restaurante Cafe receipt)
  # Total: $557.90 (Subtotal items sum)
  # Note: quantity is always 1 since we use line totals
  EXPECTED_ENCANTO_1_ITEMS = [
    { name: "Pumpkin Hot Cakes", quantity: 1, price: 159.00, is_modifier: false },
    { name: "Latte", quantity: 1, price: 130.00, is_modifier: false },
    { name: "Leche Deslactosada", quantity: 1, price: 10.00, is_modifier: true },
    { name: "Leche Coco", quantity: 1, price: 10.00, is_modifier: true },
    { name: "Esencia Vainilla", quantity: 1, price: 20.00, is_modifier: true },
    { name: "Machaca", quantity: 1, price: 169.00, is_modifier: false },
    { name: "Bebida", quantity: 1, price: 39.90, is_modifier: false },
    { name: "Leche Coco", quantity: 1, price: 10.00, is_modifier: true },
    { name: "Esencia Vainilla", quantity: 1, price: 10.00, is_modifier: true }
  ].freeze

  # Expected data for encanto-2.jpeg (Encanto Restaurante Cafe receipt)
  # Total: $676.80
  EXPECTED_ENCANTO_2_ITEMS = [
    { name: "Pan Con Ajo Extra", quantity: 1, price: 39.00, is_modifier: false },
    { name: "Alfredo Chicken", quantity: 1, price: 189.00, is_modifier: false },
    { name: "Pimiento Fetuccini C", quantity: 1, price: 189.00, is_modifier: false },
    { name: "Latte", quantity: 1, price: 130.00, is_modifier: false },
    { name: "Leche Deslactosada", quantity: 1, price: 10.00, is_modifier: true },
    { name: "Leche Coco", quantity: 1, price: 10.00, is_modifier: true },
    { name: "Esencia Menta", quantity: 1, price: 10.00, is_modifier: true },
    { name: "Esencia Vainilla", quantity: 1, price: 10.00, is_modifier: true },
    { name: "Bebida 39.90", quantity: 1, price: 79.80, is_modifier: false },
    { name: "Leche Deslactosada", quantity: 1, price: 10.00, is_modifier: true }
  ].freeze

  # Expected data for las-nuevas-gastronomicas.jpg (Las Nuevas Gastronomicas receipt)
  # Total: $1178.00
  # Note: Lines without prices (Agua Natural, See Server, Medium Well, N/a) should be skipped
  EXPECTED_LAS_NUEVAS_ITEMS = [
    { name: "Limonada", quantity: 1, price: 66.00, is_modifier: false },
    { name: "Bohemia Obs", quantity: 1, price: 74.00, is_modifier: false },
    { name: "Chelada", quantity: 1, price: 15.00, is_modifier: false },
    { name: "Indio", quantity: 1, price: 59.00, is_modifier: false },
    { name: "Tortilla Soup", quantity: 1, price: 115.00, is_modifier: false },
    { name: "SouthWest RibEye", quantity: 1, price: 485.00, is_modifier: false },
    { name: "Chi Ck PestPasta", quantity: 1, price: 299.00, is_modifier: false },
    { name: "Elote", quantity: 1, price: 65.00, is_modifier: false }
  ].freeze

  test "parses encanto-1 receipt correctly" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("encanto-1.jpeg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify total matches expected (line totals summed)
    # Receipt shows: Total $557.90
    parsed_total = items.sum { |item| item[:price] }
    expected_total = 557.90
    assert_in_delta expected_total, parsed_total, 10.0,
      "Total should be close to $#{expected_total}, got $#{parsed_total}"

    # Verify specific item-price pairs are correct (line totals)
    expected_prices = {
      "pumpkin" => 159.00,
      "latte" => 130.00,
      "machaca" => 169.00
    }

    expected_prices.each do |name_fragment, expected_price|
      matching_item = items.find { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_item, "Should find item containing '#{name_fragment}'"
      assert_in_delta expected_price, matching_item[:price], 1.0,
        "#{name_fragment} should have price ~$#{expected_price}, got $#{matching_item[:price]}"
    end

    # Verify modifiers are present with correct prices
    modifiers = items.select { |item| item[:is_modifier] }
    leche_modifiers = modifiers.select { |m| m[:name].downcase.include?("leche") }
    assert leche_modifiers.any?, "Should have milk modifier items"
    leche_modifiers.each do |m|
      assert_in_delta 10.0, m[:price], 1.0, "Leche modifier should cost ~$10"
    end
  end

  test "parses encanto-2 receipt correctly with line totals" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("encanto-2.jpeg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify total matches the receipt exactly
    # Receipt total is $676.80
    parsed_total = items.sum { |item| item[:price] }
    expected_total = 676.80
    assert_in_delta expected_total, parsed_total, 5.0,
      "Total should be close to $#{expected_total}, got $#{parsed_total}"

    # Verify specific item-price pairs are correct (these are LINE TOTALS)
    expected_prices = {
      "pan con ajo" => 39.00,
      "alfredo" => 189.00,
      "fetuccini" => 189.00,
      "latte" => 130.00,  # Line total for 2 lattes, not unit price
      "bebida" => 79.80   # Line total for 2 bebidas, not unit price
    }

    expected_prices.each do |name_fragment, expected_price|
      matching_item = items.find { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_item, "Should find item containing '#{name_fragment}'"
      assert_in_delta expected_price, matching_item[:price], 1.0,
        "#{name_fragment} should have price ~$#{expected_price}, got $#{matching_item[:price]}"
    end

    # Verify we have 10 items
    assert_equal 10, items.count,
      "Should have exactly 10 items, got #{items.count}"
  end

  test "parses las-nuevas-gastronomicas receipt correctly and skips lines without prices" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("las-nuevas-gastronomicas.jpg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify total matches the receipt exactly
    # Receipt total is $1178.00
    parsed_total = items.sum { |item| item[:price] }
    expected_total = 1178.00
    assert_in_delta expected_total, parsed_total, 5.0,
      "Total should be close to $#{expected_total}, got $#{parsed_total}"

    # Verify specific item-price pairs are correct (these are the actual receipt values)
    expected_prices = {
      "limonada" => 66.00,
      "bohemia" => 74.00,
      "chelada" => 15.00,
      "indio" => 59.00,
      "tortilla" => 115.00,
      "rib" => 485.00,
      "pasta" => 299.00,
      "elote" => 65.00
    }

    expected_prices.each do |name_fragment, expected_price|
      matching_item = items.find { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_item, "Should find item containing '#{name_fragment}'"
      assert_in_delta expected_price, matching_item[:price], 1.0,
        "#{name_fragment} should have price ~$#{expected_price}, got $#{matching_item[:price]}"
    end

    # Verify lines without prices are NOT included as standalone items
    no_price_lines = ["Agua Natural", "See Server", "Medium Well"]

    no_price_lines.each do |excluded_name|
      matching_item = items.find { |item| item[:name].downcase == excluded_name.downcase }
      assert_nil matching_item,
        "Should NOT include '#{excluded_name}' as standalone item (line without price)"
    end

    # Verify we have exactly 8 items (the ones with prices on the receipt)
    assert_equal 8, items.count,
      "Should have exactly 8 items (those with prices), got #{items.count}"
  end

  # Expected data for alsuper.png (Alsuper grocery store receipt)
  # Total: $1661.53
  # This is a grocery store receipt with different format than restaurant receipts
  EXPECTED_ALSUPER_ITEMS = [
    { name: "Pasta Para Baril", quantity: 1, price: 19.90, is_modifier: false },
    { name: "Pasta Para Baril", quantity: 1, price: 69.90, is_modifier: false },
    { name: "Salsa Para Prego", quantity: 1, price: 76.90, is_modifier: false },
    { name: "Chile Chip La Co", quantity: 1, price: 31.90, is_modifier: false },
    { name: "Papel Alum Mimar", quantity: 1, price: 39.80, is_modifier: false },
    { name: "Caja Edna Esp Horne", quantity: 1, price: 1128.05, is_modifier: false },
    { name: "Queso Meno Sello", quantity: 1, price: 92.38, is_modifier: false },
    { name: "Crema Acida Lala", quantity: 1, price: 41.90, is_modifier: false },
    { name: "Mantequilla Gl", quantity: 1, price: 114.90, is_modifier: false }
  ].freeze

  test "parses alsuper.png grocery receipt correctly with specialized prompt" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("alsuper.png")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/png")
    items = service.parse

    assert_not_empty items, "Should parse items from Alsuper receipt"

    # Verify restaurant name is "Alsuper"
    assert_equal "Alsuper", service.restaurant_name,
      "Restaurant name should be 'Alsuper', got '#{service.restaurant_name}'"

    # Verify total matches the receipt (TOTAL VENTA: 1661.53)
    expected_total = 1661.53
    assert_in_delta expected_total, service.receipt_total, 5.0,
      "Receipt total should be close to $#{expected_total}, got $#{service.receipt_total}"

    # Verify specific grocery items are present (prices may vary slightly due to OCR)
    # Use shorter fragments since OCR may truncate names
    expected_items = ["crema", "mantequ", "queso"]

    expected_items.each do |name_fragment|
      matching_items = items.select { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_items.any?, "Should find item containing '#{name_fragment}', items: #{items.map { |i| i[:name] }.join(', ')}"
    end

    # Verify we have multiple items parsed (should be 8-12 items typically)
    assert items.count >= 5, "Should have at least 5 items, got #{items.count}"
    assert items.count <= 15, "Should have at most 15 items, got #{items.count}"

    # Verify NO modifiers (grocery items don't have modifiers)
    modifiers = items.select { |item| item[:is_modifier] }
    assert_empty modifiers, "Grocery items should not have any modifiers"

    # Verify excluded items are NOT present (these should never be items)
    # Note: Category headers like "abarrote" may slip through but the important thing is
    # that non-product lines like payment info, loyalty program, etc. are excluded
    excluded_terms = ["redondeo", "promocion", "club alsuper", "visa", "carnet", "iva ", "ahorro"]
    excluded_terms.each do |term|
      matching = items.find { |item| item[:name].downcase.include?(term) }
      assert_nil matching, "Should NOT include '#{term}' as an item"
    end
  end

  # Expected data for wild-rooster.jpeg (Wild Rooster Wing Bar receipt)
  # Total: $1689.00 (Subtotal: $1455.99 + IVA: $233.01)
  # Item prices already include IVA (they sum to Total)
  # Combo 2 items have sub-lines (Boneless, Papa Gajo) with no prices — should be skipped
  EXPECTED_WILD_ROOSTER_ITEMS = [
    { name: "Coca Zero", quantity: 1, price: 41.00, is_modifier: false },
    { name: "Coca Zero", quantity: 1, price: 41.00, is_modifier: false },
    { name: "Bohemia Media", quantity: 1, price: 50.00, is_modifier: false },
    { name: "Chamuca", quantity: 1, price: 19.00, is_modifier: false },
    { name: "Indio Media", quantity: 1, price: 44.00, is_modifier: false },
    { name: "Combo 2", quantity: 1, price: 219.00, is_modifier: false },
    { name: "Rebanada Chocoflan", quantity: 1, price: 99.00, is_modifier: false },
    { name: "Coca Zero", quantity: 1, price: 41.00, is_modifier: false },
    { name: "Tarro Soda", quantity: 1, price: 78.00, is_modifier: false },
    { name: "Tarro Soda", quantity: 1, price: 78.00, is_modifier: false },
    { name: "Bohemia Media", quantity: 1, price: 50.00, is_modifier: false },
    { name: "Indio Media", quantity: 1, price: 44.00, is_modifier: false },
    { name: "Tarro Soda", quantity: 1, price: 78.00, is_modifier: false },
    { name: "Bohemia Media", quantity: 1, price: 50.00, is_modifier: false },
    { name: "Combo 2", quantity: 1, price: 219.00, is_modifier: false },
    { name: "Vaso Michelado", quantity: 1, price: 18.00, is_modifier: false },
    { name: "Bohemia Media", quantity: 1, price: 50.00, is_modifier: false },
    { name: "Combo 2", quantity: 1, price: 219.00, is_modifier: false },
    { name: "Vaso Michelado", quantity: 1, price: 18.00, is_modifier: false },
    { name: "Bohemia Media", quantity: 1, price: 50.00, is_modifier: false },
    { name: "Aceituna Preparadas", quantity: 1, price: 81.00, is_modifier: false },
    { name: "Tarro Mich Obs", quantity: 1, price: 102.00, is_modifier: false }
  ].freeze

  test "parses wild-rooster receipt correctly" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("wild-rooster.jpeg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify receipt total
    assert_in_delta 1689.00, service.receipt_total, 5.0,
      "Receipt total should be close to $1689.00, got $#{service.receipt_total}"

    # Verify restaurant name
    assert service.restaurant_name.to_s.downcase.include?("wild") || service.restaurant_name.to_s.downcase.include?("rooster"),
      "Restaurant name should contain 'wild' or 'rooster', got '#{service.restaurant_name}'"

    # Verify items sum equals receipt total (prices already include IVA)
    parsed_total = items.sum { |item| item[:price] }
    assert_in_delta 1689.00, parsed_total, 10.0,
      "Items sum should be close to $1689.00, got $#{parsed_total}"

    # Verify key items are present
    expected_prices = {
      "combo" => 219.00,
      "chocoflan" => 99.00,
      "chamuca" => 19.00,
      "aceituna" => 81.00,
      "tarro mich" => 102.00
    }

    expected_prices.each do |name_fragment, expected_price|
      matching_item = items.find { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_item, "Should find item containing '#{name_fragment}'"
      assert_in_delta expected_price, matching_item[:price], 2.0,
        "#{name_fragment} should have price ~$#{expected_price}, got $#{matching_item[:price]}"
    end

    # Verify we have 22 priced items (sub-items without prices like Boneless, Papa Gajo should be skipped)
    assert items.count >= 18, "Should have at least 18 items, got #{items.count}"
    assert items.count <= 25, "Should have at most 25 items, got #{items.count}"

    # Verify 3 Combo 2 items
    combos = items.select { |item| item[:name].downcase.include?("combo") }
    assert_equal 3, combos.count, "Should have 3 Combo 2 items, got #{combos.count}"

    # Verify 3 Coca Zero items
    cocas = items.select { |item| item[:name].downcase.include?("coca") }
    assert_equal 3, cocas.count, "Should have 3 Coca Zero items, got #{cocas.count}"
  end

  # Expected data for chihua-restaurant.jpeg (Chihua Restaurant buffet receipt)
  # Total: $1584.00 (Subtotal: $1365.52 + IVA: $218.48)
  # IVA is distributed proportionally across items so they sum to the total
  # Ratio: 1584.00 / 1365.52 = 1.15993...
  # Note: quantity is always 1 since we use line totals
  EXPECTED_CHIHUA_ITEMS = [
    { name: "Buffet", quantity: 1, price: 1394.96, is_modifier: false },
    { name: "Buffet Nito", quantity: 1, price: 118.99, is_modifier: false },
    { name: "Cafe Combo", quantity: 1, price: 0.00, is_modifier: false },
    { name: "Leche Con Chocolate", quantity: 1, price: 35.00, is_modifier: false },
    { name: "Refresco", quantity: 1, price: 35.00, is_modifier: false }
  ].freeze

  test "parses chihua-restaurant buffet receipt correctly" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("chihua-restaurant.jpeg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify items sum equals the receipt total (IVA distributed across items)
    # Receipt total is $1584.00 (subtotal $1365.52 + IVA $218.48)
    parsed_total = items.sum { |item| item[:price] }
    expected_total = 1584.00
    assert_in_delta expected_total, parsed_total, 2.0,
      "Items sum (with IVA distributed) should be close to $#{expected_total}, got $#{parsed_total}"

    # Verify receipt_total matches
    assert_in_delta 1584.00, service.receipt_total, 5.0,
      "Receipt total should be close to $1584.00, got $#{service.receipt_total}"

    # Verify specific item-price pairs are correct (line totals WITH IVA distributed)
    # IVA ratio: 1584.00 / 1365.52 ≈ 1.16
    expected_prices = {
      "buffet" => 1394.96,
      "nito" => 118.99,
      "refresco" => 35.00,
      "chocolate" => 35.00
    }

    expected_prices.each do |name_fragment, expected_price|
      matching_item = items.find { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_item, "Should find item containing '#{name_fragment}'"
      assert_in_delta expected_price, matching_item[:price], 2.0,
        "#{name_fragment} should have price ~$#{expected_price}, got $#{matching_item[:price]}"
    end

    # Verify NO modifiers (buffet items don't have modifiers)
    modifiers = items.select { |item| item[:is_modifier] }
    assert_empty modifiers, "Buffet items should not have any modifiers"

    # Verify we have 4-5 items (cafe combo at $0.00 may or may not be included)
    assert items.count >= 4, "Should have at least 4 items, got #{items.count}"
    assert items.count <= 6, "Should have at most 6 items, got #{items.count}"
  end

  # Expected data for il-fornaio.jpeg (IL Fornaio receipt)
  # Total: $1288.00 (Subtotal: $1110.34 + IVA: $177.66)
  # Note: This receipt has IVA that should ideally be distributed across items
  EXPECTED_IL_FORNAIO_ITEMS = [
    { name: "Capricciosa", quantity: 1, price: 200.00, is_modifier: false },
    { name: "Pizza Peperoni", quantity: 1, price: 210.00, is_modifier: false },
    { name: "Arlecchino", quantity: 1, price: 240.00, is_modifier: false },
    { name: "Tarro Chelado", quantity: 1, price: 16.00, is_modifier: false },
    { name: "Café Americano", quantity: 1, price: 120.00, is_modifier: false },
    { name: "Filetto Alla Panceta", quantity: 1, price: 360.00, is_modifier: false },
    { name: "Cerveza Premium", quantity: 1, price: 52.00, is_modifier: false },
    { name: "Refresco", quantity: 1, price: 45.00, is_modifier: false },
    { name: "Refresco", quantity: 1, price: 45.00, is_modifier: false }
  ].freeze

  test "parses il-fornaio receipt correctly" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("il-fornaio.jpeg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify receipt total
    assert_in_delta 1288.00, service.receipt_total, 5.0,
      "Receipt total should be close to $1288.00, got $#{service.receipt_total}"

    # Verify restaurant name
    assert service.restaurant_name.to_s.downcase.include?("fornaio"),
      "Restaurant name should contain 'fornaio', got '#{service.restaurant_name}'"

    # Verify items sum is close to receipt total
    parsed_total = items.sum { |item| item[:price] }
    assert_in_delta 1288.00, parsed_total, 5.0,
      "Items sum should be close to $1288.00, got $#{parsed_total}"

    # Verify specific items are present
    expected_prices = {
      "capricciosa" => 200.00,
      "peperoni" => 210.00,
      "arlecchino" => 240.00,
      "chelado" => 16.00,
      "americano" => 120.00,
      "filetto" => 360.00,
      "cerveza" => 52.00
    }

    expected_prices.each do |name_fragment, expected_price|
      matching_item = items.find { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_item, "Should find item containing '#{name_fragment}'"
      assert_in_delta expected_price, matching_item[:price], 2.0,
        "#{name_fragment} should have price ~$#{expected_price}, got $#{matching_item[:price]}"
    end

    # Verify two Refresco items
    refrescos = items.select { |item| item[:name].downcase.include?("refresco") }
    assert_equal 2, refrescos.count, "Should have 2 Refresco items, got #{refrescos.count}"

    # Verify we have 9 items
    assert_equal 9, items.count, "Should have exactly 9 items, got #{items.count}"

    # Verify NO modifiers
    modifiers = items.select { |item| item[:is_modifier] }
    assert_empty modifiers, "IL Fornaio items should not have any modifiers"
  end

  # Expected data for churreria-porfirio.jpeg (Churreria Porfirio receipt)
  # Total: $186.00 (Subtotal: $160.34 + Impuestos 16%: $25.66)
  # This receipt has grouped items: "Cafe $87" is actually Café de Olla ($75) + Leche Deslactosada ($12)
  # Item prices already include tax (they sum to Total, not Subtotal)
  EXPECTED_PORFIRIO_ITEMS = [
    { name: "Café de Olla", quantity: 1, price: 75.00, is_modifier: false },
    { name: "Leche Deslactosada", quantity: 1, price: 12.00, is_modifier: true },
    { name: "Rellenos", quantity: 1, price: 99.00, is_modifier: false }
  ].freeze

  test "parses churreria-porfirio receipt correctly with sub-items" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("churreria-porfirio.jpeg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify receipt total
    assert_in_delta 186.00, service.receipt_total, 5.0,
      "Receipt total should be close to $186.00, got $#{service.receipt_total}"

    # Verify restaurant name
    assert service.restaurant_name.to_s.downcase.include?("porfirio"),
      "Restaurant name should contain 'porfirio', got '#{service.restaurant_name}'"

    # Verify items sum equals receipt total (prices already include tax)
    parsed_total = items.sum { |item| item[:price] }
    assert_in_delta 186.00, parsed_total, 2.0,
      "Items sum should be close to $186.00, got $#{parsed_total}"

    # CRITICAL: Cafe ($87) should be broken down into sub-items, NOT a single "Cafe" item
    cafe_item = items.find { |item| item[:name].downcase == "cafe" && item[:price] == 87.00 }
    assert_nil cafe_item,
      "Should NOT have a single 'Cafe' item at $87 — it should be broken into sub-items (Café de Olla $75 + Leche Deslactosada $12)"

    # Verify Café de Olla is extracted as main item
    cafe_olla = items.find { |item| item[:name].downcase.include?("caf") && item[:name].downcase.include?("olla") }
    assert cafe_olla, "Should find 'Café de Olla' as a sub-item"
    assert_in_delta 75.00, cafe_olla[:price], 1.0,
      "Café de Olla should have price ~$75.00, got $#{cafe_olla[:price]}"

    # Verify Leche Deslactosada is extracted as modifier
    leche = items.find { |item| item[:name].downcase.include?("leche") || item[:name].downcase.include?("deslactosada") }
    assert leche, "Should find 'Leche Deslactosada' as a sub-item"
    assert_in_delta 12.00, leche[:price], 1.0,
      "Leche Deslactosada should have price ~$12.00, got $#{leche[:price]}"
    assert leche[:is_modifier], "Leche Deslactosada should be a modifier"

    # Verify Rellenos
    rellenos = items.find { |item| item[:name].downcase.include?("relleno") }
    assert rellenos, "Should find 'Rellenos' item"
    assert_in_delta 99.00, rellenos[:price], 1.0,
      "Rellenos should have price ~$99.00, got $#{rellenos[:price]}"
  end

  # Expected data for dayva-bar.jpeg (Dayva Bar receipt)
  # Receipt Total: $2,048.00
  # Items sum: $2,047.00 (difference: $1.00)
  # 17 items, no modifiers (bar/restaurant items)
  EXPECTED_DAYVA_BAR_ITEMS = [
    { name: "REFRESCO", quantity: 1, price: 280.00, is_modifier: false },
    { name: "DAYVASO DOBLE", quantity: 1, price: 198.00, is_modifier: false },
    { name: "CAGUAMA CARTA BLANCA", quantity: 1, price: 198.00, is_modifier: false },
    { name: "CARTA BLANCA 325ML", quantity: 1, price: 98.00, is_modifier: false },
    { name: "DAYVASO SAL", quantity: 1, price: 55.00, is_modifier: false },
    { name: "CARNE SECA PREPARADA", quantity: 1, price: 165.00, is_modifier: false },
    { name: "COMBO 1", quantity: 1, price: 145.00, is_modifier: false },
    { name: "DAYVAPAPAS KKLY RIE", quantity: 1, price: 140.00, is_modifier: false },
    { name: "DAYVANACHOS ESPECIAL", quantity: 1, price: 135.00, is_modifier: false },
    { name: "FRESA COLADA S/H", quantity: 1, price: 120.00, is_modifier: false },
    { name: "CAGUAMA INDIO", quantity: 1, price: 99.00, is_modifier: false },
    { name: "CAGUAMA MILLER", quantity: 1, price: 99.00, is_modifier: false },
    { name: "CAGUAMA XX LAGER", quantity: 1, price: 99.00, is_modifier: false },
    { name: "PAPAS CON QUESO", quantity: 1, price: 89.00, is_modifier: false },
    { name: "MILLER 325ML", quantity: 1, price: 62.00, is_modifier: false },
    { name: "LIMONA VASO", quantity: 1, price: 55.00, is_modifier: false },
    { name: "ESCARCHADO CAGUAMA", quantity: 1, price: 10.00, is_modifier: false }
  ].freeze

  test "parses dayva-bar receipt correctly" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("dayva-bar.jpeg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify receipt total
    assert_in_delta 2048.00, service.receipt_total, 5.0,
      "Receipt total should be close to $2048.00, got $#{service.receipt_total}"

    # Verify restaurant name
    assert service.restaurant_name.to_s.downcase.include?("dayva"),
      "Restaurant name should contain 'dayva', got '#{service.restaurant_name}'"

    # Verify items sum is close to receipt total
    parsed_total = items.sum { |item| item[:price] }
    assert_in_delta 2048.00, parsed_total, 5.0,
      "Items sum should be close to $2048.00, got $#{parsed_total}"

    # Verify specific items are present
    expected_prices = {
      "dayvaso doble" => 198.00,
      "carne seca" => 165.00,
      "combo" => 145.00,
      "dayvanachos" => 135.00,
      "fresa colada" => 120.00,
      "papas con queso" => 89.00,
      "escarchado" => 10.00
    }

    expected_prices.each do |name_fragment, expected_price|
      matching_item = items.find { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_item, "Should find item containing '#{name_fragment}'"
      assert_in_delta expected_price, matching_item[:price], 2.0,
        "#{name_fragment} should have price ~$#{expected_price}, got $#{matching_item[:price]}"
    end

    # Verify caguama items (3 different brands)
    caguamas = items.select { |item| item[:name].downcase.include?("caguama") }
    assert caguamas.count >= 3, "Should have at least 3 caguama items, got #{caguamas.count}"

    # Verify we have 17 items
    assert items.count >= 15, "Should have at least 15 items, got #{items.count}"
    assert items.count <= 20, "Should have at most 20 items, got #{items.count}"

    # Verify NO modifiers (bar items don't have modifiers)
    modifiers = items.select { |item| item[:is_modifier] }
    assert_empty modifiers, "Bar items should not have any modifiers"
  end

  # Expected data for el-comal.jpeg (Restaurante El Comal Chihuahua receipt)
  # Receipt Total (Neto/G.TOTAL): $708.00 (Subtotal: $610.34 + IVA: $97.66)
  # Items on receipt already show IVA-inclusive prices that sum to $708.00
  # IMPORTANT: The parser should NOT add IVA again on top of these prices.
  # 3 items, no modifiers. DESAYUNO LUNES-J qty 2 = $498 line total.
  EXPECTED_EL_COMAL_ITEMS = [
    { name: "BUFFET", quantity: 1, price: 150.00, is_modifier: false },
    { name: "DESAYUNO LUNES-J", quantity: 1, price: 498.00, is_modifier: false },
    { name: "JUGO DE NARANJA", quantity: 1, price: 60.00, is_modifier: false }
  ].freeze

  test "parses el-comal receipt correctly without double-counting IVA" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("el-comal.jpeg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify receipt total
    assert_in_delta 708.00, service.receipt_total, 5.0,
      "Receipt total should be close to $708.00, got $#{service.receipt_total}"

    # Verify restaurant name
    assert service.restaurant_name.to_s.downcase.include?("comal"),
      "Restaurant name should contain 'comal', got '#{service.restaurant_name}'"

    # CRITICAL: Items sum must equal receipt total ($708), NOT $819.52
    # The receipt prices already include IVA — the parser should not distribute IVA again
    parsed_total = items.sum { |item| item[:price] }
    assert_in_delta 708.00, parsed_total, 5.0,
      "Items sum should be close to $708.00 (IVA already included in item prices), got $#{parsed_total}. " \
      "If this fails with ~$819.52, the parser is double-counting IVA."

    # Verify specific items with exact prices as printed on receipt
    expected_prices = {
      "buffet" => 150.00,
      "desayuno" => 498.00,
      "jugo" => 60.00
    }

    expected_prices.each do |name_fragment, expected_price|
      matching_item = items.find { |item| item[:name].downcase.include?(name_fragment) }
      assert matching_item, "Should find item containing '#{name_fragment}'"
      assert_in_delta expected_price, matching_item[:price], 2.0,
        "#{name_fragment} should have price ~$#{expected_price}, got $#{matching_item[:price]}"
    end

    # Verify we have 3 items
    assert_equal 3, items.count,
      "Should have exactly 3 items, got #{items.count}"

    # Verify NO modifiers
    modifiers = items.select { |item| item[:is_modifier] }
    assert_empty modifiers, "El Comal items should not have any modifiers"
  end

  # Expected data for la-cabana-smokehouse.jpg (La Cabaña Smokehouse receipt)
  # Receipt Total: $4,932.00 (Subtotal: $4,251.72 + IVA: $680.28)
  # Item prices are PRE-TAX (sum to Subtotal), so IVA must be distributed.
  # Notable items: BRISKET SH (3x) $837, RACK DE CERDO (2x) $898, TABLA BRISKET $779
  # Several items with $0 price (included sides, 100% discounts)
  EXPECTED_LA_CABANA_ITEMS = [
    { name: "CHELADO", quantity: 1, price: 24.00, is_modifier: false },
    { name: "BOHEMIA OBSCURA", quantity: 1, price: 118.00, is_modifier: false },
    { name: "CLAMATO CHICO", quantity: 1, price: 49.00, is_modifier: false },
    { name: "CLAMATO GRANDE", quantity: 1, price: 69.00, is_modifier: false },
    { name: "INDIO", quantity: 1, price: 90.00, is_modifier: false },
    { name: "SH BUNS (4 PZA)", quantity: 1, price: 35.00, is_modifier: false },
    { name: "BRISKET SH", quantity: 1, price: 837.00, is_modifier: false },
    { name: "TABLA BRISKET", quantity: 1, price: 779.00, is_modifier: false },
    { name: "QUESADILLA PULLED PO", quantity: 1, price: 159.00, is_modifier: false },
    { name: "RACK DE CERDO", quantity: 1, price: 898.00, is_modifier: false }
    # ... plus more items, free sides at $0, etc.
  ].freeze

  test "parses la-cabana-smokehouse receipt correctly with IVA distribution" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("la-cabana-smokehouse.jpg")
    service = ClaudeReceiptParserService.new(image_path.to_s, "image/jpeg")
    items = service.parse

    assert_not_empty items, "Should parse items from receipt"

    # Verify receipt total
    assert_in_delta 4932.00, service.receipt_total, 5.0,
      "Receipt total should be close to $4932.00, got $#{service.receipt_total}"

    # Verify restaurant name
    assert service.restaurant_name.to_s.downcase.include?("cabaña") || service.restaurant_name.to_s.downcase.include?("cabana") || service.restaurant_name.to_s.downcase.include?("smokehouse"),
      "Restaurant name should contain 'cabaña' or 'smokehouse', got '#{service.restaurant_name}'"

    # Items sum must equal receipt total ($4,932) after IVA distribution
    # Pre-tax subtotal is $4,251.72, so without IVA distribution it would be ~$4,252
    parsed_total = items.sum { |item| item[:price] }
    assert_in_delta 4932.00, parsed_total, 10.0,
      "Items sum should be close to $4932.00 (with IVA distributed), got $#{parsed_total}. " \
      "If this fails with ~$4252, IVA was not distributed."

    # Verify key high-value items are present with correct prices (pre-IVA, scaled by ~1.16)
    # BRISKET SH: $837 pre-tax -> ~$970 with IVA
    brisket = items.find { |item| item[:name].downcase.include?("brisket") && !item[:name].downcase.include?("tabla") }
    assert brisket, "Should find BRISKET SH item"
    assert brisket[:price] >= 837.0, "BRISKET SH should have price >= $837 (with IVA: ~$970), got $#{brisket[:price]}"

    # TABLA BRISKET: $779 pre-tax -> ~$903 with IVA
    tabla = items.find { |item| item[:name].downcase.include?("tabla") }
    assert tabla, "Should find TABLA BRISKET item"
    assert tabla[:price] >= 779.0, "TABLA BRISKET should have price >= $779 (with IVA: ~$903), got $#{tabla[:price]}"

    # RACK DE CERDO: $898 pre-tax -> ~$1041 with IVA (might be 2 items)
    rack_items = items.select { |item| item[:name].downcase.include?("rack") && item[:name].downcase.include?("cerdo") }
    assert rack_items.any?, "Should find RACK DE CERDO item(s)"

    # Verify we have a reasonable number of items (20-30 expected based on receipt)
    assert items.count >= 15, "Should have at least 15 items, got #{items.count}"
    assert items.count <= 35, "Should have at most 35 items, got #{items.count}"
  end

  test "returns empty array for non-existent file" do
    service = ReceiptParserService.new("/non/existent/path.jpg", "image/jpeg")
    items = service.parse

    assert_equal [], items
  end

  test "returns empty array for blank path" do
    service = ReceiptParserService.new("", "image/jpeg")
    items = service.parse

    assert_equal [], items
  end
end