defmodule MydiaWeb.DashboardLive.FranchiseFastAddTest do
  @moduledoc """
  A fast add from the dashboard fills in the library only when the movie's
  franchise answers (#1293). An explicit library always wins.
  """

  # Points the global metadata relay URL at a Bypass server.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  setup %{conn: conn} do
    # DashboardLive.Index loads both trending rails on connected mount (#530).
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    tmdb_id = 920_000_000 + System.unique_integer([:positive])
    sibling_id = 920_000_000 + System.unique_integer([:positive])
    collection_id = System.unique_integer([:positive])

    chosen = library_path_fixture(%{type: "movies"})
    franchise = library_path_fixture(%{type: "movies"})

    media_item_fixture(%{
      type: "movie",
      title: "Starfall Protocol #{sibling_id}",
      tmdb_id: sibling_id,
      library_path_id: franchise.id
    })

    stub_franchise_movie(point_relay_at_bypass(), tmdb_id, collection_id, [tmdb_id, sibling_id])

    conn = log_in_user(conn, user_fixture(%{role: "admin"}))
    {:ok, view, _html} = live(conn, ~p"/")

    %{view: view, tmdb_id: tmdb_id, chosen: chosen, franchise: franchise}
  end

  # A render round trip runs after the add, which handle_info does inline.
  defp fast_add(view, tmdb_id, library_path_id) do
    send(view.pid, {:add_media_to_library, {:tmdb, tmdb_id}, :movie, library_path_id})
    render(view)
    Repo.get_by!(MediaItem, tmdb_id: tmdb_id, type: "movie")
  end

  test "with no library given, the movie lands beside its franchise", ctx do
    assert fast_add(ctx.view, ctx.tmdb_id, nil).library_path_id == ctx.franchise.id
  end

  test "an explicit library is kept", ctx do
    assert fast_add(ctx.view, ctx.tmdb_id, ctx.chosen.id).library_path_id == ctx.chosen.id
  end
end
