defmodule MydiaWeb.DiscoverLive.FranchiseFastAddTest do
  @moduledoc """
  A fast add from Discover, with no library picked, lands a franchise movie in
  the library its siblings live in (#1293), ahead of the instance default.
  """

  # Points the global metadata relay URL at a Bypass server.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  setup %{conn: conn} do
    # DiscoverLive.Index loads these on connected mount (#530).
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])

    %{conn: log_in_user(conn, create_admin_user())}
  end

  test "a fast add with no library lands beside the franchise", %{conn: conn} do
    tmdb_id = 910_000_000 + System.unique_integer([:positive])
    sibling_id = 910_000_000 + System.unique_integer([:positive])
    collection_id = System.unique_integer([:positive])

    default = library_path_fixture(%{type: "movies"})
    Mydia.Settings.set_default_library(default, :movies)
    franchise = library_path_fixture(%{type: "movies"})

    media_item_fixture(%{
      type: "movie",
      title: "Starfall Protocol #{sibling_id}",
      tmdb_id: sibling_id,
      library_path_id: franchise.id
    })

    stub_franchise_movie(point_relay_at_bypass(), tmdb_id, collection_id, [tmdb_id, sibling_id])

    {:ok, view, _html} = live(conn, ~p"/discover")
    send(view.pid, {:add_media_to_library, {:tmdb, tmdb_id}, :movie, nil})
    # A render round trip runs after the add, which handle_info does inline.
    render(view)

    assert %MediaItem{library_path_id: library_path_id} =
             Repo.get_by(MediaItem, tmdb_id: tmdb_id, type: "movie")

    assert library_path_id == franchise.id
  end
end
