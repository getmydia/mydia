defmodule Mydia.Repo.Migrations.AddSpecializedLibraryTypes do
  @moduledoc """
  Adds music, books, and adult types to the library_paths.type enum.

  SQLite: Recreates the table with updated CHECK constraint.
  PostgreSQL: Drops and recreates the CHECK constraint with new values.
  """
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  def up do
    for_database(
      sqlite: fn -> sqlite_recreate_table_up() end,
      postgres: fn ->
        # Drop old constraint and add new one with additional types
        execute "ALTER TABLE library_paths DROP CONSTRAINT IF EXISTS library_paths_type_check"

        execute """
        ALTER TABLE library_paths
        ADD CONSTRAINT library_paths_type_check
        CHECK (type IN ('movies', 'series', 'mixed', 'music', 'books', 'adult'))
        """
      end
    )
  end

  def down do
    for_database(
      sqlite: fn -> sqlite_recreate_table_down() end,
      postgres: fn ->
        # Restore old constraint (will fail if new type values exist)
        execute "ALTER TABLE library_paths DROP CONSTRAINT IF EXISTS library_paths_type_check"

        execute """
        ALTER TABLE library_paths
        ADD CONSTRAINT library_paths_type_check
        CHECK (type IN ('movies', 'series', 'mixed'))
        """
      end
    )
  end

  # SQLite: Recreate table with new CHECK constraint including music, books, adult
  defp sqlite_recreate_table_up do
    # Dropping library_paths fires media_files.library_path_id ON DELETE CASCADE,
    # which deletes every media file row. The wrapper snapshots and restores it.
    preserving_fk_children(:library_paths, fn ->
      execute """
      CREATE TABLE library_paths_new (
        id TEXT PRIMARY KEY NOT NULL,
        path TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL CHECK(type IN ('movies', 'series', 'mixed', 'music', 'books', 'adult')),
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
      """

      execute """
      INSERT INTO library_paths_new
      SELECT id, path, type, monitored, scan_interval, last_scan_at, last_scan_status,
             last_scan_error, quality_profile_id, updated_by_id, inserted_at, updated_at
      FROM library_paths
      """

      execute "DROP TABLE library_paths"
      execute "ALTER TABLE library_paths_new RENAME TO library_paths"

      # Recreate indexes
      execute "CREATE INDEX library_paths_monitored_index ON library_paths (monitored)"
      execute "CREATE INDEX library_paths_type_index ON library_paths (type)"

      execute "CREATE INDEX library_paths_quality_profile_id_index ON library_paths (quality_profile_id)"
    end)
  end

  # SQLite: Recreate table with old CHECK constraint (movies, series, mixed only)
  defp sqlite_recreate_table_down do
    # Dropping library_paths fires media_files.library_path_id ON DELETE CASCADE,
    # which deletes every media file row. The wrapper snapshots and restores it.
    preserving_fk_children(:library_paths, fn ->
      execute """
      CREATE TABLE library_paths_new (
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
      """

      execute """
      INSERT INTO library_paths_new
      SELECT id, path, type, monitored, scan_interval, last_scan_at, last_scan_status,
             last_scan_error, quality_profile_id, updated_by_id, inserted_at, updated_at
      FROM library_paths
      """

      execute "DROP TABLE library_paths"
      execute "ALTER TABLE library_paths_new RENAME TO library_paths"

      execute "CREATE INDEX library_paths_monitored_index ON library_paths (monitored)"
      execute "CREATE INDEX library_paths_type_index ON library_paths (type)"

      execute "CREATE INDEX library_paths_quality_profile_id_index ON library_paths (quality_profile_id)"
    end)
  end
end
