defmodule Mydia.Repo.Migrations.PreservingFkChildrenTest do
  use Mydia.MigrationCase

  defmodule RebuildParentMigration do
    use Ecto.Migration
    import Mydia.Repo.Migrations.Helpers

    def up do
      preserving_fk_children(:parent, fn ->
        execute "CREATE TABLE parent_new (id TEXT PRIMARY KEY, label TEXT)"
        execute "INSERT INTO parent_new (id, label) SELECT id, label FROM parent"
        execute "DROP TABLE parent"
        execute "ALTER TABLE parent_new RENAME TO parent"
      end)
    end
  end

  defmodule ReversibleRebuildMigration do
    use Ecto.Migration
    import Mydia.Repo.Migrations.Helpers

    def up do
      rebuild_parent_as("CREATE TABLE parent_new (id TEXT PRIMARY KEY, label TEXT)")
    end

    def down do
      rebuild_parent_as(
        "CREATE TABLE parent_new (id TEXT PRIMARY KEY, label TEXT, dead_column TEXT)"
      )
    end

    defp rebuild_parent_as(create_sql) do
      preserving_fk_children(:parent, fn ->
        execute create_sql
        execute "INSERT INTO parent_new (id, label) SELECT id, label FROM parent"
        execute "DROP TABLE parent"
        execute "ALTER TABLE parent_new RENAME TO parent"
      end)
    end
  end

  defmodule ChangeRebuildMigration do
    use Ecto.Migration
    import Mydia.Repo.Migrations.Helpers

    def change do
      preserving_fk_children(:parent, fn ->
        execute "CREATE TABLE parent_new (id TEXT PRIMARY KEY, label TEXT)"
        execute "INSERT INTO parent_new (id, label) SELECT id, label FROM parent"
        execute "DROP TABLE parent"
        execute "ALTER TABLE parent_new RENAME TO parent"
      end)
    end
  end

  defp build_schema do
    sql!("CREATE TABLE parent (id TEXT PRIMARY KEY, label TEXT, dead_column TEXT)")

    sql!("""
    CREATE TABLE kid_cascade (id TEXT PRIMARY KEY,
      p TEXT REFERENCES parent(id) ON DELETE CASCADE)
    """)

    sql!("""
    CREATE TABLE kid_null (id TEXT PRIMARY KEY,
      p TEXT REFERENCES parent(id) ON DELETE SET NULL)
    """)

    sql!("CREATE TABLE kid_noaction (id TEXT PRIMARY KEY, p TEXT REFERENCES parent(id))")

    sql!("INSERT INTO parent (id, label, dead_column) VALUES ('p1', 'kept', 'junk')")
    sql!("INSERT INTO kid_cascade (id, p) VALUES ('c1', 'p1')")
    sql!("INSERT INTO kid_null (id, p) VALUES ('n1', 'p1')")
    sql!("INSERT INTO kid_noaction (id, p) VALUES ('a1', 'p1')")
  end

  @tag :tmp_dir
  test "a cascade child keeps its rows" do
    build_schema()
    run_migration!(RebuildParentMigration, 20_260_101_000_010)

    assert %{rows: [["c1", "p1"]]} = sql!("SELECT id, p FROM kid_cascade")
  end

  @tag :tmp_dir
  test "a set null child keeps its assignment" do
    build_schema()
    run_migration!(RebuildParentMigration, 20_260_101_000_011)

    assert %{rows: [["n1", "p1"]]} = sql!("SELECT id, p FROM kid_null")
  end

  @tag :tmp_dir
  test "a no action child does not abort the rebuild" do
    build_schema()
    run_migration!(RebuildParentMigration, 20_260_101_000_012)

    assert %{rows: [["a1", "p1"]]} = sql!("SELECT id, p FROM kid_noaction")
  end

  @tag :tmp_dir
  test "the rebuild itself still happens" do
    build_schema()
    run_migration!(RebuildParentMigration, 20_260_101_000_013)

    assert %{rows: [["p1", "kept"]]} = sql!("SELECT id, label FROM parent")

    columns =
      sql!(~s|PRAGMA table_info("parent")|).rows
      |> Enum.map(fn [_cid, name | _] -> name end)

    refute "dead_column" in columns
  end

  @tag :tmp_dir
  test "leaves no snapshot tables behind and no violations" do
    build_schema()
    run_migration!(RebuildParentMigration, 20_260_101_000_014)

    %{rows: leftovers} =
      sql!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '__mydia_fk_snap_%'"
      )

    assert leftovers == []
    assert %{rows: []} = sql!("PRAGMA foreign_key_check")
  end

  @tag :tmp_dir
  test "preserves a grandchild through a cascading chain" do
    sql!("CREATE TABLE parent (id TEXT PRIMARY KEY, label TEXT)")

    sql!(
      "CREATE TABLE child (id TEXT PRIMARY KEY, p TEXT REFERENCES parent(id) ON DELETE CASCADE)"
    )

    sql!("""
    CREATE TABLE grandchild (id TEXT PRIMARY KEY,
      c TEXT REFERENCES child(id) ON DELETE CASCADE)
    """)

    sql!("INSERT INTO parent (id, label) VALUES ('p1', 'kept')")
    sql!("INSERT INTO child (id, p) VALUES ('c1', 'p1')")
    sql!("INSERT INTO grandchild (id, c) VALUES ('g1', 'c1')")

    run_migration!(RebuildParentMigration, 20_260_101_000_015)

    assert %{rows: [["c1", "p1"]]} = sql!("SELECT id, p FROM child")
    assert %{rows: [["g1", "c1"]]} = sql!("SELECT id, c FROM grandchild")
  end

  @tag :tmp_dir
  test "a migration with an explicit down/0 rolls back through the primitive" do
    build_schema()
    run_migration!(ReversibleRebuildMigration, 20_260_101_000_017)

    assert :ok = rollback_migration!(ReversibleRebuildMigration, 20_260_101_000_017)

    columns =
      sql!(~s|PRAGMA table_info("parent")|).rows
      |> Enum.map(fn [_cid, name | _] -> name end)

    assert "dead_column" in columns
  end

  @tag :tmp_dir
  test "the foreign key children survive the rollback too" do
    build_schema()
    run_migration!(ReversibleRebuildMigration, 20_260_101_000_018)
    rollback_migration!(ReversibleRebuildMigration, 20_260_101_000_018)

    assert %{rows: [["c1", "p1"]]} = sql!("SELECT id, p FROM kid_cascade")
    assert %{rows: [["n1", "p1"]]} = sql!("SELECT id, p FROM kid_null")
    assert %{rows: [["a1", "p1"]]} = sql!("SELECT id, p FROM kid_noaction")
    assert %{rows: []} = sql!("PRAGMA foreign_key_check")
  end

  @tag :tmp_dir
  test "rolling back a change/0 migration still raises, naming change/0" do
    build_schema()
    run_migration!(ChangeRebuildMigration, 20_260_101_000_019)

    message =
      assert_raise Ecto.MigrationError, fn ->
        rollback_migration!(ChangeRebuildMigration, 20_260_101_000_019)
      end

    assert message.message =~ "ChangeRebuildMigration"
    assert message.message =~ "change/0"
    assert message.message =~ "explicit up/0 and down/0"
  end

  @tag :tmp_dir
  test "a failed change/0 rollback leaves the children untouched" do
    build_schema()
    run_migration!(ChangeRebuildMigration, 20_260_101_000_020)

    assert_raise Ecto.MigrationError, fn ->
      rollback_migration!(ChangeRebuildMigration, 20_260_101_000_020)
    end

    assert %{rows: [["c1", "p1"]]} = sql!("SELECT id, p FROM kid_cascade")
    assert %{rows: [["n1", "p1"]]} = sql!("SELECT id, p FROM kid_null")
    assert %{rows: [["a1", "p1"]]} = sql!("SELECT id, p FROM kid_noaction")
  end

  @tag :tmp_dir
  test "does nothing when the table has no children" do
    sql!("CREATE TABLE parent (id TEXT PRIMARY KEY, label TEXT)")
    sql!("INSERT INTO parent (id, label) VALUES ('p1', 'kept')")

    run_migration!(RebuildParentMigration, 20_260_101_000_016)

    assert %{rows: [["p1", "kept"]]} = sql!("SELECT id, label FROM parent")
  end
end
