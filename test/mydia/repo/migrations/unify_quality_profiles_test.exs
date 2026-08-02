defmodule Mydia.Repo.Migrations.UnifyQualityProfilesTest do
  use Mydia.MigrationCase

  Code.require_file("priv/repo/migrations/20260628000000_unify_quality_profiles.exs")

  alias Mydia.Repo.Migrations.UnifyQualityProfiles

  defp build_schema do
    sql!("""
    CREATE TABLE quality_profiles (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      upgrades_allowed INTEGER DEFAULT 1,
      upgrade_until_quality TEXT,
      description TEXT,
      is_system INTEGER DEFAULT 0,
      version INTEGER DEFAULT 1,
      source_url TEXT,
      last_synced_at TEXT,
      quality_standards TEXT,
      qualities TEXT,
      metadata_preferences TEXT,
      customizations TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("CREATE UNIQUE INDEX quality_profiles_name_index ON quality_profiles (name)")

    sql!("""
    CREATE TABLE media_files (id TEXT PRIMARY KEY,
      quality_profile_id TEXT REFERENCES quality_profiles(id))
    """)

    sql!("""
    CREATE TABLE media_items (id TEXT PRIMARY KEY,
      quality_profile_id TEXT REFERENCES quality_profiles(id) ON DELETE SET NULL)
    """)

    sql!("""
    CREATE TABLE library_paths (id TEXT PRIMARY KEY,
      quality_profile_id TEXT REFERENCES quality_profiles(id) ON DELETE SET NULL)
    """)

    sql!("""
    CREATE TABLE import_lists (id TEXT PRIMARY KEY,
      quality_profile_id TEXT REFERENCES quality_profiles(id) ON DELETE SET NULL)
    """)

    sql!("""
    INSERT INTO quality_profiles
      (id, name, quality_standards, qualities, metadata_preferences, customizations,
       inserted_at, updated_at)
    VALUES ('qp1', 'HD', '{}', '["hdtv-720p"]', '{}', '{}',
       '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    sql!("INSERT INTO media_files (id, quality_profile_id) VALUES ('mf1', 'qp1')")
    sql!("INSERT INTO media_items (id, quality_profile_id) VALUES ('mi1', 'qp1')")
    sql!("INSERT INTO library_paths (id, quality_profile_id) VALUES ('lp1', 'qp1')")
    sql!("INSERT INTO import_lists (id, quality_profile_id) VALUES ('il1', 'qp1')")
  end

  defp columns_of(table) do
    sql!(~s|PRAGMA table_info("#{table}")|).rows
    |> Enum.map(fn [_cid, name | _] -> name end)
  end

  @tag :tmp_dir
  test "drops the three dead columns" do
    build_schema()
    run_migration!(UnifyQualityProfiles, 20_260_101_000_030)

    columns = columns_of("quality_profiles")

    refute "qualities" in columns
    refute "metadata_preferences" in columns
    refute "customizations" in columns
    assert "quality_standards" in columns
  end

  @tag :tmp_dir
  test "does not abort when a media_files row carries a profile" do
    build_schema()
    run_migration!(UnifyQualityProfiles, 20_260_101_000_031)

    assert %{rows: [["mf1", "qp1"]]} = sql!("SELECT id, quality_profile_id FROM media_files")
  end

  @tag :tmp_dir
  test "keeps every set null assignment, including import_lists" do
    build_schema()
    run_migration!(UnifyQualityProfiles, 20_260_101_000_032)

    assert %{rows: [["mi1", "qp1"]]} = sql!("SELECT id, quality_profile_id FROM media_items")
    assert %{rows: [["lp1", "qp1"]]} = sql!("SELECT id, quality_profile_id FROM library_paths")
    assert %{rows: [["il1", "qp1"]]} = sql!("SELECT id, quality_profile_id FROM import_lists")
  end

  @tag :tmp_dir
  test "still backfills preferred resolutions into quality_standards" do
    build_schema()
    run_migration!(UnifyQualityProfiles, 20_260_101_000_033)

    %{rows: [[standards]]} = sql!("SELECT quality_standards FROM quality_profiles")
    refute standards == "{}"
  end

  @tag :tmp_dir
  test "replays cleanly against an already migrated database" do
    build_schema()
    run_migration!(UnifyQualityProfiles, 20_260_101_000_034)
    run_migration!(UnifyQualityProfiles, 20_260_101_000_035)

    assert %{rows: [["qp1"]]} = sql!("SELECT id FROM quality_profiles")
  end
end
