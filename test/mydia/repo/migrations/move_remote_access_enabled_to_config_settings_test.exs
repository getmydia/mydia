defmodule Mydia.Repo.Migrations.MoveRemoteAccessEnabledToConfigSettingsTest do
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20260911131949_move_remote_access_enabled_to_config_settings.exs"
  )

  alias Mydia.Repo.Migrations.MoveRemoteAccessEnabledToConfigSettings

  @version 20_260_911_131_949

  defp build_schema(enabled) do
    sql!("""
    CREATE TABLE remote_access_config (
      id TEXT PRIMARY KEY NOT NULL,
      instance_id TEXT,
      enabled INTEGER NOT NULL DEFAULT 0,
      direct_urls TEXT,
      cert_fingerprint TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    CREATE TABLE config_settings (
      id TEXT PRIMARY KEY NOT NULL,
      key TEXT NOT NULL,
      value TEXT,
      category TEXT NOT NULL,
      description TEXT,
      updated_by_id TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("CREATE UNIQUE INDEX config_settings_key_index ON config_settings (key)")

    if is_boolean(enabled) do
      sql!(
        """
        INSERT INTO remote_access_config (id, instance_id, enabled, inserted_at, updated_at)
        VALUES ('cfg1', 'instance-1', ?, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
        """,
        [if(enabled, do: 1, else: 0)]
      )
    end
  end

  defp setting_rows, do: sql!("SELECT key, value, category FROM config_settings").rows

  # PRAGMA table_info returns one row per column; the name is the second field.
  defp columns(table) do
    sql!("PRAGMA table_info(#{table})").rows |> Enum.map(&Enum.at(&1, 1))
  end

  @tag :tmp_dir
  test "carries an administrator's off into config_settings" do
    build_schema(false)

    run_migration!(MoveRemoteAccessEnabledToConfigSettings, @version)

    assert setting_rows() == [["remote_access.enabled", "false", "remote_access"]]
  end

  @tag :tmp_dir
  test "writes nothing for an install that has remote access on" do
    build_schema(true)

    run_migration!(MoveRemoteAccessEnabledToConfigSettings, @version)

    assert setting_rows() == []
  end

  @tag :tmp_dir
  test "writes nothing when no config row exists" do
    build_schema(:no_row)

    run_migration!(MoveRemoteAccessEnabledToConfigSettings, @version)

    assert setting_rows() == []
  end

  @tag :tmp_dir
  test "drops the enabled column and keeps the identity" do
    build_schema(true)

    run_migration!(MoveRemoteAccessEnabledToConfigSettings, @version)

    refute "enabled" in columns("remote_access_config")
    assert "instance_id" in columns("remote_access_config")
  end

  @tag :tmp_dir
  test "rolling back restores the column and the off" do
    build_schema(false)

    run_migration!(MoveRemoteAccessEnabledToConfigSettings, @version)
    rollback_migration!(MoveRemoteAccessEnabledToConfigSettings, @version)

    assert %{rows: [[0]]} = sql!("SELECT enabled FROM remote_access_config WHERE id = 'cfg1'")
    assert setting_rows() == []
  end
end
