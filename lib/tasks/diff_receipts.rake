namespace :receipts do
  desc "List all saved diff receipts with their metadata"
  task list: :environment do
    diff_dir = Rails.root.join("storage", "diff_receipts")

    unless Dir.exist?(diff_dir)
      puts "No diff_receipts directory found."
      next
    end

    json_files = Dir.glob(diff_dir.join("*.json")).sort
    if json_files.empty?
      puts "No diff receipts saved yet."
      next
    end

    puts "=" * 70
    puts "DIFF RECEIPTS (#{json_files.count} total)"
    puts "=" * 70

    json_files.each_with_index do |json_path, idx|
      metadata = JSON.parse(File.read(json_path))
      base_name = File.basename(json_path, ".json")
      image_ext = metadata["content_type"]&.include?("png") ? ".png" : ".jpeg"
      image_exists = File.exist?(diff_dir.join("#{base_name}#{image_ext}")) ||
                     File.exist?(diff_dir.join("#{base_name}.jpg")) ||
                     File.exist?(diff_dir.join("#{base_name}.jpeg")) ||
                     File.exist?(diff_dir.join("#{base_name}.png"))

      puts "\n#{idx + 1}. #{metadata['restaurant_name'] || 'Unknown'}"
      puts "   Date:       #{metadata['saved_at']}"
      puts "   Diff:       $#{format('%.2f', metadata['difference'])}"
      puts "   Receipt:    $#{format('%.2f', metadata['receipt_total'])} | Items: $#{format('%.2f', metadata['items_sum'])}"
      puts "   Items:      #{metadata['item_count']}"
      puts "   Image:      #{image_exists ? '✅' : '❌ MISSING'} #{base_name}#{image_ext}"
      puts "   Metadata:   #{File.basename(json_path)}"
    end

    puts "\n" + "=" * 70
    puts "Directory: #{diff_dir}"
    puts "=" * 70
  end

  desc "Watch for new diff receipts (poll every N seconds, default 30)"
  task watch: :environment do
    diff_dir = Rails.root.join("storage", "diff_receipts")
    FileUtils.mkdir_p(diff_dir)

    interval = (ENV["INTERVAL"] || 30).to_i
    seen = Set.new(Dir.glob(diff_dir.join("*.json")).map { |f| File.basename(f) })

    puts "👀 Watching #{diff_dir} for new diff receipts (every #{interval}s)..."
    puts "   #{seen.count} existing receipts found. Press Ctrl+C to stop.\n\n"

    loop do
      current = Dir.glob(diff_dir.join("*.json")).map { |f| File.basename(f) }
      new_files = current - seen.to_a

      new_files.each do |json_file|
        json_path = diff_dir.join(json_file)
        metadata = JSON.parse(File.read(json_path))

        puts "🆕 NEW DIFF RECEIPT: #{metadata['restaurant_name'] || 'Unknown'}"
        puts "   Diff: $#{format('%.2f', metadata['difference'])} | Total: $#{format('%.2f', metadata['receipt_total'])}"
        puts "   Items: #{metadata['item_count']} | Saved: #{metadata['saved_at']}"
        puts "   File: #{json_file}"
        puts ""

        seen.add(json_file)
      end

      sleep interval
    end
  rescue Interrupt
    puts "\n\nStopped watching."
  end

  desc "Copy a diff receipt to test fixtures. Usage: rake receipts:promote FILE=<json_filename>"
  task promote: :environment do
    diff_dir = Rails.root.join("storage", "diff_receipts")
    fixtures_dir = Rails.root.join("test", "fixtures", "files")

    file = ENV["FILE"]
    unless file
      puts "Usage: rake receipts:promote FILE=<json_filename>"
      puts "Run 'rake receipts:list' to see available files."
      next
    end

    json_path = diff_dir.join(file.end_with?(".json") ? file : "#{file}.json")
    unless File.exist?(json_path)
      puts "❌ File not found: #{json_path}"
      next
    end

    metadata = JSON.parse(File.read(json_path))
    base_name = File.basename(json_path, ".json")

    # Find the image file
    image_file = Dir.glob(diff_dir.join("#{base_name}.*")).find { |f| !f.end_with?(".json") }
    unless image_file
      puts "❌ Image file not found for #{base_name}"
      next
    end

    # Generate fixture name from restaurant
    safe_name = (metadata["restaurant_name"] || "unknown").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
    ext = File.extname(image_file)

    # Check for existing fixture with same name and add suffix
    fixture_name = "#{safe_name}#{ext}"
    counter = 2
    while File.exist?(fixtures_dir.join(fixture_name))
      fixture_name = "#{safe_name}-#{counter}#{ext}"
      counter += 1
    end

    # Copy image to fixtures
    dest = fixtures_dir.join(fixture_name)
    FileUtils.cp(image_file, dest)

    puts "✅ Promoted to test fixture:"
    puts "   From:       #{File.basename(image_file)}"
    puts "   To:         test/fixtures/files/#{fixture_name}"
    puts "   Restaurant: #{metadata['restaurant_name']}"
    puts "   Diff:       $#{format('%.2f', metadata['difference'])}"
    puts "   Total:      $#{format('%.2f', metadata['receipt_total'])}"
    puts "\n   Metadata saved alongside for reference."

    # Also copy metadata to fixtures dir for reference
    FileUtils.cp(json_path, fixtures_dir.join("#{File.basename(fixture_name, ext)}.json"))
  end
end
