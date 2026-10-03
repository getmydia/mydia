defmodule MydiaWeb.SearchLive.RestrictedMetadataSearchTest do
  @moduledoc """
  `/search` is open to every signed-in account, and its manual metadata search
  returns provider hits, not library rows. They must go through
  `Mydia.Media.RemoteFilter`, or a restricted account can browse and pick
  out-of-bounds titles from the "match this release" modal.
  """

  # The stub provider registry and the metadata cache are global.
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers, only: [warm_remote_signals: 3]
  import Mydia.MetadataStub
  import Phoenix.LiveViewTest

  alias Mydia.MetadataStubProvider
  alias Mydia.Media.RemoteSignals

  setup :setup_metadata_stub

  setup do
    warm_remote_signals(
      {:tmdb, MetadataStubProvider.movie_tmdb_id()},
      :movie,
      %RemoteSignals{category: "movie"}
    )

    :ok
  end

  defp matched_titles(conn, user) do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/search")

    render_hook(view, "manual_search_submit", %{"search_query" => "Stub"})
    render_async(view)

    # Read from the assigns: the manual-search modal renders its matches only
    # while open, and only a failed release add opens it, so there is no
    # markup to assert on from a bare /search mount.
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(:metadata_matches)
    |> Enum.map(& &1.title)
  end

  test "a category-restricted account does not get an out-of-bounds hit", %{conn: conn} do
    user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

    assert matched_titles(conn, user) == []
  end

  test "an account allowed that category keeps the hit", %{conn: conn} do
    user = restricted_user_fixture(%{allowed_categories: ["movie"]})

    assert matched_titles(conn, user) == [MetadataStubProvider.movie_title()]
  end

  test "an unrestricted account keeps the hit", %{conn: conn} do
    assert matched_titles(conn, user_fixture()) == [MetadataStubProvider.movie_title()]
  end
end
