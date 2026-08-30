defmodule Mydia.Repo.Migrations.HelpersTest do
  use Mydia.MigrationCase

  defmodule AddParentCheckMigration do
    use Ecto.Migration
    import Mydia.Repo.Migrations.Helpers

    def up do
      recreate_table(
        table: :media_files,
        primary_key: false,
        timestamps: false,
        columns: [
          {:id, :text, [primary_key: true]},
          {:media_item_id, :text, []},
          {:episode_id, :text, []}
        ],
        checks: [{:media_files_has_parent, "media_item_id IS NOT NULL OR episode_id IS NOT NULL"}]
      )
    end
  end

  @tag :tmp_dir
  test "recreate_table puts named checks in SQLite table definitions" do
    sql!("CREATE TABLE media_files (id TEXT PRIMARY KEY, media_item_id TEXT, episode_id TEXT)")
    sql!("INSERT INTO media_files (id, media_item_id) VALUES ('owned', 'movie-1')")

    run_migration!(AddParentCheckMigration, 20_260_830_143_722)

    %{rows: [[definition]]} =
      sql!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'media_files'")

    assert definition =~
             "CONSTRAINT media_files_has_parent CHECK (media_item_id IS NOT NULL OR episode_id IS NOT NULL)"

    assert_raise Exqlite.Error, fn ->
      sql!("INSERT INTO media_files (id) VALUES ('parentless')")
    end
  end
end
