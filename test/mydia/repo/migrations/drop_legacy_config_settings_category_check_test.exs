defmodule Mydia.Repo.Migrations.DropLegacyConfigSettingsCategoryCheckTest do
  @moduledoc """
  Databases created before the raw-SQL migrations were converted to the Ecto DSL
  (f9521c0c9) still carry `CHECK(category IN (...))` on `config_settings`, which
  rejects every category added since. The migration rebuilds the table without
  it, so these tests cover what a rebuild can get wrong.
  """
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20261013015421_drop_legacy_config_settings_category_check.exs"
  )

  alias Mydia.Repo.Migrations.DropLegacyConfigSettingsCategoryCheck

  @version 20_261_013_015_421

  @tag :tmp_dir
  test "a newer category saves once the CHECK is gone" do
    seed_legacy_schema()

    assert_raise Exqlite.Error, ~r/CHECK constraint failed/, fn ->
      insert_setting("s1", "cardigann.engine", "cardigann")
    end

    run_migration!(DropLegacyConfigSettingsCategoryCheck, @version)

    insert_setting("s1", "cardigann.engine", "cardigann")
    assert %{rows: [["cardigann"]]} = sql!("SELECT category FROM config_settings")
  end

  @tag :tmp_dir
  test "existing rows and their updated_by_id survive the rebuild" do
    seed_legacy_schema()
    sql!("INSERT INTO users (id) VALUES ('u1')")
    insert_setting("s1", "crash_reporting.enabled", "crash_reporting", "u1")

    run_migration!(DropLegacyConfigSettingsCategoryCheck, @version)

    assert %{rows: [["s1", "crash_reporting.enabled", "true", "crash_reporting", "u1"]]} =
             sql!("SELECT id, key, value, category, updated_by_id FROM config_settings")
  end

  @tag :tmp_dir
  test "deleting the user still nulls updated_by_id rather than cascading" do
    seed_legacy_schema()
    sql!("INSERT INTO users (id) VALUES ('u1')")
    insert_setting("s1", "media.x", "media", "u1")

    run_migration!(DropLegacyConfigSettingsCategoryCheck, @version)
    sql!("DELETE FROM users WHERE id = 'u1'")

    assert %{rows: [["s1", nil]]} = sql!("SELECT id, updated_by_id FROM config_settings")
  end

  @tag :tmp_dir
  test "key stays unique and both indexes exist" do
    seed_legacy_schema()
    run_migration!(DropLegacyConfigSettingsCategoryCheck, @version)

    insert_setting("s1", "dup.key", "media")

    assert_raise Exqlite.Error, ~r/UNIQUE constraint failed/, fn ->
      insert_setting("s2", "dup.key", "media")
    end

    assert %{rows: rows} =
             sql!("""
             SELECT name FROM sqlite_master
             WHERE type = 'index' AND tbl_name = 'config_settings' AND name NOT LIKE 'sqlite_%'
             ORDER BY name
             """)

    assert List.flatten(rows) == ["config_settings_category_index", "config_settings_key_index"]
  end

  @tag :tmp_dir
  test "it is a no-op on a table without the CHECK" do
    sql!("""
    CREATE TABLE config_settings (
      id TEXT PRIMARY KEY,
      key TEXT NOT NULL,
      modern_marker TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    run_migration!(DropLegacyConfigSettingsCategoryCheck, @version)

    assert %{rows: [[sql]]} =
             sql!(
               "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'config_settings'"
             )

    assert sql =~ "modern_marker"
  end

  @tag :tmp_dir
  test "running it twice is harmless" do
    seed_legacy_schema()
    run_migration!(DropLegacyConfigSettingsCategoryCheck, @version)
    rollback_migration!(DropLegacyConfigSettingsCategoryCheck, @version)
    run_migration!(DropLegacyConfigSettingsCategoryCheck, @version)

    insert_setting("s1", "cardigann.engine", "cardigann")
  end

  # The table exactly as galactica has it (read from sqlite_master on 2026-10-12).
  defp seed_legacy_schema do
    sql!("CREATE TABLE users (id TEXT PRIMARY KEY NOT NULL)")

    sql!("""
    CREATE TABLE "config_settings" (
      id TEXT PRIMARY KEY NOT NULL,
      key TEXT NOT NULL UNIQUE,
      value TEXT,
      category TEXT NOT NULL CHECK(category IN ('server', 'auth', 'media', 'downloads', 'notifications', 'crash_reporting', 'general')),
      description TEXT,
      updated_by_id TEXT REFERENCES users(id) ON DELETE SET NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!(~s|CREATE INDEX "config_settings_category_index" ON "config_settings" ("category")|)
    sql!(~s|CREATE INDEX "config_settings_key_index" ON "config_settings" ("key")|)
  end

  defp insert_setting(id, key, category, updated_by_id \\ nil) do
    sql!(
      """
      INSERT INTO config_settings (id, key, value, category, updated_by_id, inserted_at, updated_at)
      VALUES (?1, ?2, 'true', ?3, ?4, '2026-10-12 00:00:00', '2026-10-12 00:00:00')
      """,
      [id, key, category, updated_by_id]
    )
  end
end
