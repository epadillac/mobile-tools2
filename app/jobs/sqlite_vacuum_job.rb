class SqliteVacuumJob < ApplicationJob
  queue_as :maintenance

  # Run VACUUM on every SQLite-backed connection — primary plus the Solid
  # Cache/Queue/Cable shards. After heavy churn (Solid Queue inserts/deletes a
  # lot of rows), the WAL and free pages can dwarf the live data; VACUUM
  # rewrites the file and shrinks it back down.
  #
  # WAL mode means readers aren't blocked, but VACUUM holds an exclusive
  # write lock for its duration. Schedule it during a low-traffic window.
  def perform
    ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |cfg|
      next unless cfg.adapter.in?(%w[sqlite3 litedb])

      ActiveRecord::Base.connected_to(shard: cfg.name.to_sym, role: :writing) do
        before = db_size_bytes(cfg.database)
        ActiveRecord::Base.connection.execute("VACUUM")
        after = db_size_bytes(cfg.database)
        Rails.logger.info(
          "[SqliteVacuumJob] #{cfg.name} (#{cfg.database}): " \
          "#{format_size(before)} → #{format_size(after)}"
        )
      end
    rescue StandardError => e
      # One shard failing shouldn't abort the rest.
      Rails.logger.error("[SqliteVacuumJob] #{cfg.name} failed: #{e.class}: #{e.message}")
    end
  end

  private

  def db_size_bytes(path)
    File.size?(path).to_i
  end

  def format_size(bytes)
    return "0 B" if bytes.zero?
    units = %w[B KB MB GB]
    exp   = (Math.log(bytes) / Math.log(1024)).to_i.clamp(0, units.length - 1)
    format("%.1f %s", bytes.to_f / (1024**exp), units[exp])
  end
end
