defmodule Mydia.Repo.Migrations.FkChildrenTest do
  use Mydia.MigrationCase

  alias Mydia.Repo.Migrations.Helpers

  @tag :tmp_dir
  test "returns an empty list when nothing references the table" do
    sql!("CREATE TABLE lonely (id TEXT PRIMARY KEY)")

    assert Helpers.sqlite_fk_children(Mydia.MigrationTestRepo, "lonely") == []
  end

  @tag :tmp_dir
  test "finds direct children regardless of their on delete action" do
    sql!("CREATE TABLE parent (id TEXT PRIMARY KEY)")

    sql!(
      "CREATE TABLE kid_cascade (id TEXT PRIMARY KEY, p TEXT REFERENCES parent(id) ON DELETE CASCADE)"
    )

    sql!(
      "CREATE TABLE kid_null (id TEXT PRIMARY KEY, p TEXT REFERENCES parent(id) ON DELETE SET NULL)"
    )

    sql!("CREATE TABLE kid_noaction (id TEXT PRIMARY KEY, p TEXT REFERENCES parent(id))")

    children = Helpers.sqlite_fk_children(Mydia.MigrationTestRepo, "parent")

    assert Enum.sort(children) == ["kid_cascade", "kid_noaction", "kid_null"]
  end

  @tag :tmp_dir
  test "orders grandchildren before children" do
    sql!("CREATE TABLE parent (id TEXT PRIMARY KEY)")

    sql!(
      "CREATE TABLE child (id TEXT PRIMARY KEY, p TEXT REFERENCES parent(id) ON DELETE CASCADE)"
    )

    sql!(
      "CREATE TABLE grandchild (id TEXT PRIMARY KEY, c TEXT REFERENCES child(id) ON DELETE CASCADE)"
    )

    assert Helpers.sqlite_fk_children(Mydia.MigrationTestRepo, "parent") ==
             ["grandchild", "child"]
  end

  @tag :tmp_dir
  test "lists a table reachable by two paths exactly once, after both" do
    sql!("CREATE TABLE parent (id TEXT PRIMARY KEY)")

    sql!(
      "CREATE TABLE left_kid (id TEXT PRIMARY KEY, p TEXT REFERENCES parent(id) ON DELETE CASCADE)"
    )

    sql!(
      "CREATE TABLE right_kid (id TEXT PRIMARY KEY, p TEXT REFERENCES parent(id) ON DELETE CASCADE)"
    )

    sql!("""
    CREATE TABLE shared (
      id TEXT PRIMARY KEY,
      l TEXT REFERENCES left_kid(id) ON DELETE CASCADE,
      r TEXT REFERENCES right_kid(id) ON DELETE CASCADE
    )
    """)

    children = Helpers.sqlite_fk_children(Mydia.MigrationTestRepo, "parent")

    assert Enum.count(children, &(&1 == "shared")) == 1

    assert Enum.find_index(children, &(&1 == "shared")) <
             Enum.find_index(children, &(&1 == "left_kid"))

    assert Enum.find_index(children, &(&1 == "shared")) <
             Enum.find_index(children, &(&1 == "right_kid"))
  end

  @tag :tmp_dir
  test "raises on a foreign key cycle" do
    sql!("CREATE TABLE a (id TEXT PRIMARY KEY, b_id TEXT REFERENCES b(id))")
    sql!("CREATE TABLE b (id TEXT PRIMARY KEY, a_id TEXT REFERENCES a(id))")

    assert_raise Ecto.MigrationError, ~r/cycle/i, fn ->
      Helpers.sqlite_fk_children(Mydia.MigrationTestRepo, "a")
    end
  end
end
