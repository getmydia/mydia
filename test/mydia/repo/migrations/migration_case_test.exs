defmodule Mydia.MigrationCaseTest do
  use Mydia.MigrationCase

  defmodule AddColumnMigration do
    use Ecto.Migration

    def up do
      alter table(:widgets) do
        add :label, :string
      end
    end
  end

  @tag :tmp_dir
  test "runs a migration against a populated temp database" do
    sql!("CREATE TABLE widgets (id TEXT PRIMARY KEY)")
    sql!("INSERT INTO widgets (id) VALUES ('w1')")

    run_migration!(AddColumnMigration, 20_260_101_000_001)

    assert %{rows: [["w1", nil]]} = sql!("SELECT id, label FROM widgets")
  end

  @tag :tmp_dir
  test "foreign keys are enforced in the harness" do
    sql!("CREATE TABLE parents (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE kids (id TEXT PRIMARY KEY, parent_id TEXT REFERENCES parents(id))")

    assert_raise Exqlite.Error, fn ->
      sql!("INSERT INTO kids (id, parent_id) VALUES ('k1', 'nope')")
    end
  end
end
