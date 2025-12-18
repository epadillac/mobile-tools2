require "test_helper"

class ReceiptParserServiceTest < ActiveSupport::TestCase
  # Expected data for r1.jpeg (Encanto Restaurante Cafe receipt)
  # Total: $557.90 (Subtotal items sum)
  # Note: quantity is always 1 since we use line totals
  EXPECTED_R1_ITEMS = [
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

  # Expected data for r2.jpeg (Encanto Restaurante Cafe receipt)
  # Total: $676.80
  EXPECTED_R2_ITEMS = [
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

  # Expected data for r3.jpg (Las Nuevas Gastronomicas receipt)
  # Total: $1178.00
  # Note: Lines without prices (Agua Natural, See Server, Medium Well, N/a) should be skipped
  EXPECTED_R3_ITEMS = [
    { name: "Limonada", quantity: 1, price: 66.00, is_modifier: false },
    { name: "Bohemia Obs", quantity: 1, price: 74.00, is_modifier: false },
    { name: "Chelada", quantity: 1, price: 15.00, is_modifier: false },
    { name: "Indio", quantity: 1, price: 59.00, is_modifier: false },
    { name: "Tortilla Soup", quantity: 1, price: 115.00, is_modifier: false },
    { name: "SouthWest RibEye", quantity: 1, price: 485.00, is_modifier: false },
    { name: "Chi Ck PestPasta", quantity: 1, price: 299.00, is_modifier: false },
    { name: "Elote", quantity: 1, price: 65.00, is_modifier: false }
  ].freeze

  test "parses r1.jpeg receipt correctly" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("r1.jpeg")
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

  test "parses r2.jpeg receipt correctly with line totals" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("r2.jpeg")
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

  test "parses r3.jpg receipt correctly and skips lines without prices" do
    skip "Requires ANTHROPIC_API_KEY to be set" if ENV["ANTHROPIC_API_KEY"].to_s.empty? && Rails.application.credentials.dig(:anthropic, :api_key).to_s.empty?

    image_path = fixture_file_path("r3.jpg")
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