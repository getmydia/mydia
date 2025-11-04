defmodule Mydia.Repo.Migrations.CreateConfigTables do
  use Ecto.Migration

  def change do
    # General configuration settings table
    execute(
      """
      CREATE TABLE config_settings (
        id TEXT PRIMARY KEY NOT NULL,
        key TEXT NOT NULL UNIQUE,
        value TEXT,
        category TEXT NOT NULL CHECK(category IN ('server', 'auth', 'media', 'downloads', 'notifications', 'general')),
        description TEXT,
        updated_by_id TEXT REFERENCES users(id) ON DELETE SET NULL,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS config_settings"
    )

    create index(:config_settings, [:category])
    create index(:config_settings, [:key])

    # Download client configurations
    execute(
      """
      CREATE TABLE download_client_configs (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL CHECK(type IN ('qbittorrent', 'transmission', 'http')),
        enabled INTEGER DEFAULT 1 CHECK(enabled IN (0, 1)),
        priority INTEGER DEFAULT 1,
        host TEXT NOT NULL,
        port INTEGER NOT NULL,
        use_ssl INTEGER DEFAULT 0 CHECK(use_ssl IN (0, 1)),
        url_base TEXT,
        username TEXT,
        password TEXT,
        api_key TEXT,
        category TEXT,
        download_directory TEXT,
        connection_settings TEXT,
        updated_by_id TEXT REFERENCES users(id) ON DELETE SET NULL,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS download_client_configs"
    )

    create index(:download_client_configs, [:enabled])
    create index(:download_client_configs, [:priority])
    create index(:download_client_configs, [:type])

    # Indexer configurations
    execute(
      """
      CREATE TABLE indexer_configs (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL CHECK(type IN ('prowlarr', 'jackett', 'public')),
        enabled INTEGER DEFAULT 1 CHECK(enabled IN (0, 1)),
        priority INTEGER DEFAULT 1,
        base_url TEXT NOT NULL,
        api_key TEXT,
        indexer_ids TEXT,
        categories TEXT,
        rate_limit INTEGER,
        connection_settings TEXT,
        updated_by_id TEXT REFERENCES users(id) ON DELETE SET NULL,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS indexer_configs"
    )

    create index(:indexer_configs, [:enabled])
    create index(:indexer_configs, [:priority])
    create index(:indexer_configs, [:type])

    # Library paths
    execute(
      """
      CREATE TABLE library_paths (
        id TEXT PRIMARY KEY NOT NULL,
        path TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL CHECK(type IN ('movies', 'series', 'mixed')),
        monitored INTEGER DEFAULT 1 CHECK(monitored IN (0, 1)),
        scan_interval INTEGER DEFAULT 3600,
        last_scan_at TEXT,
        last_scan_status TEXT CHECK(last_scan_status IS NULL OR last_scan_status IN ('success', 'failed', 'in_progress')),
        last_scan_error TEXT,
        quality_profile_id TEXT REFERENCES quality_profiles(id) ON DELETE SET NULL,
        updated_by_id TEXT REFERENCES users(id) ON DELETE SET NULL,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS library_paths"
    )

    create index(:library_paths, [:monitored])
    create index(:library_paths, [:type])
    create index(:library_paths, [:quality_profile_id])
  end
end
