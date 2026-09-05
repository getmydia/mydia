defmodule Mydia.Media.LibraryStatusMapTest do
  @moduledoc """
  `Media.get_library_status_map/0` is what DashboardLive and DiscoverLive read to
  decide whether a card says "Add" or "In library". Keyed on the bare provider
  id, a movie and a show sharing one TMDB number collapsed into a single entry
  and whichever row the query reached last decided both cards (#463).
  """

  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media

  test "keys a movie and a show sharing one tmdb id separately" do
    shared = System.unique_integer([:positive])

    movie = media_item_fixture(%{type: "movie", title: "Harbour Lights", tmdb_id: shared})

    show =
      media_item_fixture(%{type: "tv_show", title: "Harbour Lights: The Series", tmdb_id: shared})

    map = Media.get_library_status_map()

    assert map[{:movie, :tmdb, shared}][:id] == movie.id
    assert map[{:tv_show, :tmdb, shared}][:id] == show.id
  end

  test "keys a tmdb id and a tvdb id of the same number separately" do
    shared = System.unique_integer([:positive])

    by_tmdb = media_item_fixture(%{type: "tv_show", title: "Signal Hill", tmdb_id: shared})
    by_tvdb = media_item_fixture(%{type: "tv_show", title: "Second Signal", tvdb_id: shared})

    map = Media.get_library_status_map()

    assert map[{:tv_show, :tmdb, shared}][:id] == by_tmdb.id
    assert map[{:tv_show, :tvdb, shared}][:id] == by_tvdb.id
  end

  test "an item holding both ids is findable under either" do
    tmdb_id = System.unique_integer([:positive])
    tvdb_id = System.unique_integer([:positive])

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Both Ids",
        tmdb_id: tmdb_id,
        tvdb_id: tvdb_id
      })

    map = Media.get_library_status_map()

    assert map[{:tv_show, :tmdb, tmdb_id}][:id] == show.id
    assert map[{:tv_show, :tvdb, tvdb_id}][:id] == show.id
  end

  test "carries the monitored flag and type through" do
    tmdb_id = System.unique_integer([:positive])

    media_item_fixture(%{
      type: "movie",
      title: "Unwatched",
      tmdb_id: tmdb_id,
      monitored: false
    })

    assert %{in_library: true, monitored: false, type: "movie"} =
             Media.get_library_status_map()[{:movie, :tmdb, tmdb_id}]
  end

  test "skips rows with no provider id at all" do
    media_item_fixture(%{type: "movie", title: "No Provider Ids", imdb_id: "tt9999999"})

    refute Enum.any?(Media.get_library_status_map(), fn {_key, entry} ->
             entry[:type] == "movie" and entry[:id] == nil
           end)
  end
end
