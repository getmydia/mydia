defmodule Mydia.Media.LibraryPathFilterTest do
  use Mydia.DataCase, async: true

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Media.LibraryListing
  alias Mydia.Repo

  setup do
    %{
      movies_a: library_path_fixture(%{type: "movies"}),
      movies_b: library_path_fixture(%{type: "movies"}),
      series_s: library_path_fixture(%{type: "series"}),
      series_t: library_path_fixture(%{type: "series"})
    }
  end

  defp ids_in(library) do
    [library_path_id: library.id]
    |> Media.media_items_query()
    |> Repo.all()
    |> MapSet.new(& &1.id)
  end

  test "a movie matches the library its file is in", %{movies_a: a, movies_b: b} do
    movie = media_item_fixture(%{type: "movie", title: "Lanternfall"})
    media_file_fixture(%{media_item_id: movie.id, library_path_id: a.id})

    assert movie.id in ids_in(a)
    refute movie.id in ids_in(b)
  end

  test "a show matches through episode files, which carry no media_item_id",
       %{series_s: s, series_t: t} do
    show = media_item_fixture(%{type: "tv_show", title: "The Quiet Orchard"})
    episode = episode_fixture(%{media_item_id: show.id})
    file = media_file_fixture(%{episode_id: episode.id, library_path_id: s.id})

    assert is_nil(file.media_item_id)
    assert show.id in ids_in(s)
    refute show.id in ids_in(t)
  end

  test "a show split across two libraries matches both", %{series_s: s, series_t: t} do
    show = media_item_fixture(%{type: "tv_show", title: "Salt Road Stories"})
    e1 = episode_fixture(%{media_item_id: show.id, season_number: 1})
    e2 = episode_fixture(%{media_item_id: show.id, season_number: 2})
    media_file_fixture(%{episode_id: e1.id, library_path_id: s.id})
    media_file_fixture(%{episode_id: e2.id, library_path_id: t.id})

    assert show.id in ids_in(s)
    assert show.id in ids_in(t)
  end

  test "an item with no files matches its target library", %{movies_a: a, movies_b: b} do
    wanted = media_item_fixture(%{type: "movie", title: "Copperline", library_path_id: a.id})

    assert wanted.id in ids_in(a)
    refute wanted.id in ids_in(b)
  end

  test "once a file exists its location wins over the target", %{movies_a: a, movies_b: b} do
    moved = media_item_fixture(%{type: "movie", title: "Northwake", library_path_id: a.id})
    media_file_fixture(%{media_item_id: moved.id, library_path_id: b.id})

    assert moved.id in ids_in(b)
    refute moved.id in ids_in(a)
  end

  test "a trashed file does not count, so the target applies", %{movies_a: a, movies_b: b} do
    item = media_item_fixture(%{type: "movie", title: "Ember Hollow", library_path_id: a.id})
    file = media_file_fixture(%{media_item_id: item.id, library_path_id: b.id})

    {1, _} =
      Repo.update_all(from(f in MediaFile, where: f.id == ^file.id),
        set: [trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    assert item.id in ids_in(a)
    refute item.id in ids_in(b)
  end

  test "an item with no files and no target matches no library",
       %{movies_a: a, movies_b: b} do
    orphan = media_item_fixture(%{type: "movie", title: "Drift Cartography"})

    refute orphan.id in ids_in(a)
    refute orphan.id in ids_in(b)
  end

  test "LibraryListing.page/1 applies the filter", %{movies_a: a, movies_b: b} do
    in_a = media_item_fixture(%{type: "movie", title: "Glasswing"})
    media_file_fixture(%{media_item_id: in_a.id, library_path_id: a.id})
    in_b = media_item_fixture(%{type: "movie", title: "Moth Harbour"})
    media_file_fixture(%{media_item_id: in_b.id, library_path_id: b.id})

    page =
      LibraryListing.page(
        user_id: Ecto.UUID.generate(),
        type: "movie",
        library_path_id: a.id,
        limit: 50
      )

    assert in_a.id in page.visible_ids
    refute in_b.id in page.visible_ids
  end
end
