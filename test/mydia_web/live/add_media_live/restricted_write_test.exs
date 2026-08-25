defmodule MydiaWeb.AddMediaLive.RestrictedWriteTest do
  @moduledoc """
  `handle_info({:create_media_item, ...}, socket)` used to only handle
  `{:error, changeset}` and call `Ecto.Changeset.traverse_errors/2` on
  whatever came back, which raised the moment `Media.create_media_item/3`
  started being able to return the bare atom `:restricted`. This is the
  primary "search and quick-add" path a restricted `user`-role account hits.
  """

  # async: false — connected LiveView tests hit the Postgres non-shared
  # sandbox, and Provider.Registry is global process state.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.SettingsFixtures
  import Mydia.AccountsFixtures
  import Mydia.MetadataStub

  alias Mydia.Media
  alias Mydia.MetadataStubProvider

  setup :setup_metadata_stub

  setup %{conn: conn} do
    library_path_fixture(%{type: "movies"})

    restricted =
      restricted_user_fixture(%{role: "user", allowed_categories: ["cartoon_movie"]})

    %{conn: log_in_user(conn, restricted)}
  end

  test "quick-adding an out-of-bounds title flashes a friendly message instead of crashing",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/add/movie?q=stub")

    # Stub movie carries the "Action" genre, so it classifies as plain
    # "movie" -- out of bounds for a cartoon_movie-only scope.
    assert render(view) =~ MetadataStubProvider.movie_title()

    view
    |> element(~s(button[phx-click="quick_add"][phx-value-search_on_add="false"]))
    |> render_click()

    # The create runs via handle_info; give it a beat to land.
    assert render(view) =~ "This title is outside what your account is allowed to access."

    refute Media.get_media_item_by_tmdb(
             Mydia.Accounts.Scope.unrestricted(),
             MetadataStubProvider.movie_tmdb_id()
           )
  end
end
