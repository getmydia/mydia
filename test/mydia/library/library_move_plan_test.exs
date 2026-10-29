defmodule Mydia.Library.LibraryMovePlanTest do
  use Mydia.DataCase, async: false

  @moduletag :tmp_dir

  alias Mydia.Library.LibraryMove
  alias Mydia.Library.LibraryMove.Move
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  defp library(tmp, name, type, attrs \\ %{}) do
    path = Path.join(tmp, name)
    File.mkdir_p!(path)

    library_path_fixture(
      Map.merge(%{type: type, path: path, auto_organize: false, auto_rename: false}, attrs)
    )
  end

  defp put_file(library, rel, attrs) do
    abs = Path.join(library.path, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "x")

    media_file_fixture(
      Map.merge(%{library_path_id: library.id, relative_path: rel, size: 1}, attrs)
    )
  end

  test "plans a movie into the target's movie dir", %{tmp_dir: tmp} do
    a = library(tmp, "a", "movies")
    b = library(tmp, "b", "movies")
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})

    assert {:ok, [%Move{dest_path: dest, dest_rel: rel, action: :hardlink}]} =
             LibraryMove.plan(movie, b)

    assert dest == Path.join(b.path, "Glass Harbor (2019)/glass.mkv")
    assert rel == "Glass Harbor (2019)/glass.mkv"
  end

  test "plans episodes into season folders", %{tmp_dir: tmp} do
    a = library(tmp, "a", "series")
    b = library(tmp, "b", "series")
    show = media_item_fixture(%{type: "tv_show", title: "The Quiet Meridian"})
    ep = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 3})
    put_file(a, "Meridian/S1/qm.s01e03.mkv", %{episode_id: ep.id})

    assert {:ok, [move]} = LibraryMove.plan(show, b)
    assert move.dest_rel == "The Quiet Meridian/Season 01/qm.s01e03.mkv"
  end

  test "skips files already in the target and trashed files", %{tmp_dir: tmp} do
    a = library(tmp, "a", "movies")
    b = library(tmp, "b", "movies")
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    put_file(b, "Glass Harbor (2019)/kept.mkv", %{media_item_id: movie.id})
    trashed = put_file(a, "Glass Harbor (2019)/old.mkv", %{media_item_id: movie.id})
    Repo.update!(Ecto.Changeset.change(trashed, trashed_at: DateTime.utc_now(:second)))

    assert {:ok, []} = LibraryMove.plan(movie, b)
  end

  test "keeps an extra's place under the item folder", %{tmp_dir: tmp} do
    a = library(tmp, "a", "movies")
    b = library(tmp, "b", "movies")
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    extra = put_file(a, "Glass Harbor (2019)/Featurettes/making.mkv", %{media_item_id: movie.id})
    Repo.update!(Ecto.Changeset.change(extra, extra_kind: :featurette))

    {:ok, moves} = LibraryMove.plan(movie, b)
    assert "Glass Harbor (2019)/Featurettes/making.mkv" in Enum.map(moves, & &1.dest_rel)
  end

  test "auto_rename renames into the target's scheme", %{tmp_dir: tmp} do
    a = library(tmp, "a", "movies")
    b = library(tmp, "b", "movies", %{auto_rename: true})
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    put_file(a, "x/glass.harbor.2019.1080p.mkv", %{media_item_id: movie.id})

    {:ok, [move]} = LibraryMove.plan(movie, b)
    assert Path.basename(move.dest_rel) =~ "Glass Harbor"
  end
end
