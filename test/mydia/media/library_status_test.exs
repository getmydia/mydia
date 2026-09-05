defmodule Mydia.Media.LibraryStatusTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media

  test "returns an entry for each requested id that is in the library" do
    owned = media_item_fixture(%{type: "movie", title: "Owned", year: 2001, tmdb_id: 671})
    _other = media_item_fixture(%{type: "movie", title: "Other", year: 2002, tmdb_id: 672})

    status = Media.library_status_for_tmdb_ids([671, 999_001], "movie")

    assert %{671 => entry} = status
    assert entry.in_library == true
    assert entry.monitored == owned.monitored
    assert entry.type == "movie"
    assert entry.id == owned.id
    refute Map.has_key?(status, 999_001)
    refute Map.has_key?(status, 672)
  end

  test "returns an empty map for an empty id list" do
    assert Media.library_status_for_tmdb_ids([], "movie") == %{}
  end

  test "returns an empty map when nothing matches" do
    assert Media.library_status_for_tmdb_ids([999_002, 999_003], "movie") == %{}
  end

  test "ignores TV rows sharing a tmdb id with a franchise member" do
    _show =
      media_item_fixture(%{type: "tv_show", title: "Collides", tmdb_id: 999_004, year: 2010})

    assert Media.library_status_for_tmdb_ids([999_004], "movie") == %{}
  end

  test "reflects the monitored flag" do
    unmonitored =
      media_item_fixture(%{
        type: "movie",
        title: "Unmonitored",
        year: 2003,
        tmdb_id: 673,
        monitored: false
      })

    assert %{673 => %{monitored: false, id: id}} =
             Media.library_status_for_tmdb_ids([673], "movie")

    assert id == unmonitored.id
  end

  describe "get_library_status_map/0" do
    test "keys movie entries by {:movie, :tmdb, tmdb_id}" do
      movie = media_item_fixture(%{type: "movie", title: "Movie Status", tmdb_id: 12345})

      status = Media.get_library_status_map()

      assert %{in_library: true, monitored: true, type: "movie", id: id} =
               status[{:movie, :tmdb, 12345}]

      assert id == movie.id
    end

    test "keys tv show entries with tmdb_id and tvdb_id" do
      series =
        media_item_fixture(%{
          type: "tv_show",
          title: "Series Status",
          tmdb_id: 67890,
          tvdb_id: 54321
        })

      status = Media.get_library_status_map()

      assert %{in_library: true, type: "tv_show", id: id} = status[{:tv_show, :tmdb, 67890}]
      assert id == series.id
      assert %{in_library: true, type: "tv_show", id: ^id} = status[{:tv_show, :tvdb, 54321}]
    end

    test "differentiates movie and tv show with identical numeric tmdb_id" do
      shared_id = System.unique_integer([:positive])

      movie =
        media_item_fixture(%{
          type: "movie",
          title: "Shared Movie",
          tmdb_id: shared_id
        })

      show =
        media_item_fixture(%{
          type: "tv_show",
          title: "Shared Show",
          tmdb_id: shared_id
        })

      status = Media.get_library_status_map()

      assert status[{:movie, :tmdb, shared_id}].id == movie.id
      assert status[{:tv_show, :tmdb, shared_id}].id == show.id
    end
  end
end
