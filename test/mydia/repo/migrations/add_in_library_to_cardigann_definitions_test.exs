defmodule Mydia.Repo.Migrations.AddInLibraryToCardigannDefinitionsTest do
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20261011110156_add_in_library_to_cardigann_definitions.exs"
  )

  alias Mydia.Repo.Migrations.AddInLibraryToCardigannDefinitions

  defp build_schema do
    sql!("""
    CREATE TABLE cardigann_definitions (
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT,
      enabled INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    INSERT INTO cardigann_definitions (id, name, enabled, inserted_at, updated_at) VALUES
      ('on', 'On', 1, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('off', 'Off', 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)
  end

  @tag :tmp_dir
  test "an enabled definition starts in the library, a disabled one does not" do
    build_schema()

    run_migration!(AddInLibraryToCardigannDefinitions, 20_261_011_110_156)

    assert %{rows: [["off", 0], ["on", 1]]} =
             sql!("SELECT id, in_library FROM cardigann_definitions ORDER BY id")
  end
end
