defmodule Mydia.Release.TableArchiveTest do
  use Mydia.DataCase, async: false

  alias Mydia.Release.TableArchive

  @moduletag :tmp_dir

  test "writes one NDJSON line per row and reports the count", %{tmp_dir: tmp_dir} do
    Mydia.Repo.query!("CREATE TABLE archive_fixture (id INTEGER, name TEXT)")
    Mydia.Repo.query!("INSERT INTO archive_fixture (id, name) VALUES (1, 'alpha')")
    Mydia.Repo.query!("INSERT INTO archive_fixture (id, name) VALUES (2, 'beta')")

    assert {:ok, counts} = TableArchive.archive_tables(Mydia.Repo, ["archive_fixture"], tmp_dir)
    assert counts["archive_fixture"] == 2

    lines =
      Path.join(tmp_dir, "archive_fixture.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(lines) == 2
    decoded = Enum.map(lines, &Jason.decode!/1)
    assert %{"id" => 1, "name" => "alpha"} in decoded
    assert %{"id" => 2, "name" => "beta"} in decoded
  end

  test "skips an empty table and writes no file", %{tmp_dir: tmp_dir} do
    Mydia.Repo.query!("CREATE TABLE empty_fixture (id INTEGER)")

    assert {:ok, counts} = TableArchive.archive_tables(Mydia.Repo, ["empty_fixture"], tmp_dir)
    assert counts["empty_fixture"] == 0
    refute File.exists?(Path.join(tmp_dir, "empty_fixture.ndjson"))
  end

  test "returns an error rather than raising when a table does not exist", %{tmp_dir: tmp_dir} do
    assert {:error, _reason} = TableArchive.archive_tables(Mydia.Repo, ["no_such_table"], tmp_dir)
  end
end
