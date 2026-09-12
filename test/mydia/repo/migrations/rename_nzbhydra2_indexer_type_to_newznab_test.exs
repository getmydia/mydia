defmodule Mydia.Repo.Migrations.RenameNzbhydra2IndexerTypeToNewznabTest do
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20260912205942_rename_nzbhydra2_indexer_type_to_newznab.exs"
  )

  alias Mydia.Repo.Migrations.RenameNzbhydra2IndexerTypeToNewznab

  @version 20_260_912_205_942

  # The migration only rewrites `type`, so the throwaway table carries just the
  # columns the assertions read back.
  defp build_schema do
    sql!("""
    CREATE TABLE indexer_configs (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      base_url TEXT,
      connection_settings TEXT
    )
    """)

    sql!("""
    INSERT INTO indexer_configs (id, type, base_url, connection_settings)
    VALUES ('hydra', 'nzbhydra2', 'http://hydra:5076', '{"timeout":30000}')
    """)

    sql!("""
    INSERT INTO indexer_configs (id, type, base_url, connection_settings)
    VALUES ('prowlarr', 'prowlarr', 'http://prowlarr:9696', NULL)
    """)
  end

  defp row(id) do
    sql!("SELECT type, base_url, connection_settings FROM indexer_configs WHERE id = '#{id}'")
  end

  @tag :tmp_dir
  test "renames stored nzbhydra2 rows to newznab and leaves other types alone" do
    build_schema()

    run_migration!(RenameNzbhydra2IndexerTypeToNewznab, @version)

    assert %{rows: [["newznab", "http://hydra:5076", settings]]} = row("hydra")
    assert settings == ~s({"timeout":30000})

    assert %{rows: [["prowlarr", "http://prowlarr:9696", nil]]} = row("prowlarr")
  end

  @tag :tmp_dir
  test "rolling back restores the nzbhydra2 type without touching other columns" do
    build_schema()

    run_migration!(RenameNzbhydra2IndexerTypeToNewznab, @version)
    rollback_migration!(RenameNzbhydra2IndexerTypeToNewznab, @version)

    assert %{rows: [["nzbhydra2", "http://hydra:5076", settings]]} = row("hydra")
    assert settings == ~s({"timeout":30000})

    assert %{rows: [["prowlarr", "http://prowlarr:9696", nil]]} = row("prowlarr")
  end
end
