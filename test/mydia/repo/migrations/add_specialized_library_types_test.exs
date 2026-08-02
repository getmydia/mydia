defmodule Mydia.Repo.Migrations.AddSpecializedLibraryTypesTest do
  use Mydia.MigrationCase

  Code.require_file("priv/repo/migrations/20251128014213_add_specialized_library_types.exs")

  alias Mydia.Repo.Migrations.AddSpecializedLibraryTypes

  defp build_schema do
    sql!("CREATE TABLE quality_profiles (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE users (id TEXT PRIMARY KEY)")

    sql!("""
    CREATE TABLE library_paths (
      id TEXT PRIMARY KEY NOT NULL,
      path TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL CHECK(type IN ('movies', 'series', 'mixed')),
      monitored INTEGER DEFAULT 1 CHECK(monitored IN (0, 1)),
      scan_interval INTEGER DEFAULT 3600,
      last_scan_at TEXT,
      last_scan_status TEXT,
      last_scan_error TEXT,
      quality_profile_id TEXT REFERENCES quality_profiles(id) ON DELETE SET NULL,
      updated_by_id TEXT REFERENCES users(id) ON DELETE SET NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    CREATE TABLE media_files (id TEXT PRIMARY KEY,
      library_path_id TEXT REFERENCES library_paths(id) ON DELETE CASCADE)
    """)

    sql!("""
    INSERT INTO library_paths (id, path, type, inserted_at, updated_at)
    VALUES ('lp1', '/movies', 'movies', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    sql!("INSERT INTO media_files (id, library_path_id) VALUES ('mf1', 'lp1')")
  end

  @tag :tmp_dir
  test "rebuilding library_paths keeps media_files rows" do
    build_schema()
    run_migration!(AddSpecializedLibraryTypes, 20_260_101_000_040)

    assert %{rows: [["mf1", "lp1"]]} = sql!("SELECT id, library_path_id FROM media_files")
  end

  @tag :tmp_dir
  test "the widened check constraint survives the wrapper" do
    build_schema()
    run_migration!(AddSpecializedLibraryTypes, 20_260_101_000_041)

    sql!("""
    INSERT INTO library_paths (id, path, type, inserted_at, updated_at)
    VALUES ('lp2', '/music', 'music', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    assert %{rows: [["lp2", "music"]]} =
             sql!("SELECT id, type FROM library_paths WHERE id = 'lp2'")

    assert_raise Exqlite.Error, fn ->
      sql!("""
      INSERT INTO library_paths (id, path, type, inserted_at, updated_at)
      VALUES ('lp3', '/nope', 'bogus', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
      """)
    end
  end
end
