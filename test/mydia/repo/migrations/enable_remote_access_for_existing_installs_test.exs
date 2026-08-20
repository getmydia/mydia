defmodule Mydia.Repo.Migrations.EnableRemoteAccessForExistingInstallsTest do
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20260819171533_enable_remote_access_for_existing_installs.exs"
  )

  alias Mydia.Repo.Migrations.EnableRemoteAccessForExistingInstalls

  defp build_schema do
    sql!("""
    CREATE TABLE remote_access_config (
      id TEXT PRIMARY KEY NOT NULL,
      instance_id TEXT,
      static_public_key BLOB,
      static_private_key_encrypted BLOB,
      enabled INTEGER NOT NULL DEFAULT 0,
      direct_urls TEXT,
      cert_fingerprint TEXT,
      relay_token TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    INSERT INTO remote_access_config (id, instance_id, enabled, inserted_at, updated_at)
    VALUES ('cfg1', 'instance-1', 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)
  end

  @tag :tmp_dir
  test "enables a config row that was stored disabled" do
    build_schema()

    run_migration!(EnableRemoteAccessForExistingInstalls, 20_260_819_171_533)

    assert %{rows: [[1]]} = sql!("SELECT enabled FROM remote_access_config WHERE id = 'cfg1'")
  end

  @tag :tmp_dir
  test "rolling back leaves remote access alone" do
    build_schema()

    run_migration!(EnableRemoteAccessForExistingInstalls, 20_260_819_171_533)
    rollback_migration!(EnableRemoteAccessForExistingInstalls, 20_260_819_171_533)

    # up/0 does not record which rows it touched, so down/0 must not guess. A
    # blanket disable would switch off installs that were already enabled.
    assert %{rows: [[1]]} = sql!("SELECT enabled FROM remote_access_config WHERE id = 'cfg1'")
  end
end
