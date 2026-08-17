defmodule Mydia.Library.ImportGroupTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures

  alias Mydia.Library.ImportGroup
  alias Mydia.Repo

  defp valid_attrs(library_path) do
    %{
      library_path_id: library_path.id,
      anchor_path: "Cornemuse (1999)",
      cluster_key: "cornemuse",
      display_title: "Cornemuse (1999)",
      file_count: 65,
      unresolved_count: 65,
      numbered_count: 65,
      status: "pending"
    }
  end

  test "inserts a valid group" do
    library_path = library_path_fixture(%{type: "series"})

    assert {:ok, group} =
             %ImportGroup{}
             |> ImportGroup.changeset(valid_attrs(library_path))
             |> Repo.insert()

    assert group.status == "pending"
    assert group.cluster_key == "cornemuse"
  end

  test "rejects an unknown status" do
    library_path = library_path_fixture(%{type: "series"})
    attrs = %{valid_attrs(library_path) | status: "banana"}

    changeset = ImportGroup.changeset(%ImportGroup{}, attrs)

    refute changeset.valid?
    assert %{status: _} = errors_on(changeset)
  end

  test "cluster_key is unique per library path" do
    library_path = library_path_fixture(%{type: "series"})
    attrs = valid_attrs(library_path)

    assert {:ok, _} = %ImportGroup{} |> ImportGroup.changeset(attrs) |> Repo.insert()

    assert {:error, changeset} =
             %ImportGroup{} |> ImportGroup.changeset(attrs) |> Repo.insert()

    assert %{cluster_key: _} = errors_on(changeset)
  end

  test "the same cluster_key is allowed in a different library path" do
    a = library_path_fixture(%{type: "series"})
    b = library_path_fixture(%{type: "series", path: "/media/Series2"})

    assert {:ok, _} = %ImportGroup{} |> ImportGroup.changeset(valid_attrs(a)) |> Repo.insert()
    assert {:ok, _} = %ImportGroup{} |> ImportGroup.changeset(valid_attrs(b)) |> Repo.insert()
  end

  test "season_span is sorted, deduplicated, and round-trips through the database" do
    library_path = library_path_fixture(%{type: "series"})
    attrs = Map.put(valid_attrs(library_path), :season_span, [3, 1, 2, 1])

    assert {:ok, group} =
             %ImportGroup{} |> ImportGroup.changeset(attrs) |> Repo.insert()

    reloaded = Repo.get!(ImportGroup, group.id)

    assert ImportGroup.season_span(reloaded) == [1, 2, 3]
  end

  test "rejects a season_span with a non-integer element" do
    library_path = library_path_fixture(%{type: "series"})
    attrs = Map.put(valid_attrs(library_path), :season_span, [1, "two"])

    changeset = ImportGroup.changeset(%ImportGroup{}, attrs)

    refute changeset.valid?
    assert %{season_span: _} = errors_on(changeset)
  end
end
