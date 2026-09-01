defmodule MydiaWeb.DiscoverLive.NoLibrariesTest do
  # async: false — connected LiveView tests cannot use the Postgres
  # non-shared sandbox, which hides test rows from the mount process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    # DiscoverLive.Index unconditionally loads the movie genre list on
    # connected mount (#530).
    warm_genre_cache(:movie, [])

    provider_id = unique_provider_id()

    warm_movie_search_cache("quiet harbour", [], [
      %{"id" => provider_id, "title" => "Quiet Harbour", "release_date" => "2024-05-01"}
    ])

    user = user_fixture(%{role: "admin"})
    %{conn: log_in_user(conn, user)}
  end

  # With no candidate library there is nowhere to put a title. The submit
  # button stays disabled with a visible reason rather than accepting a click
  # that would fail. This matches what the deleted Add page did and must not
  # regress with the toolbar gone.
  test "the modal disables submit and says why when no library exists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

    view |> element("[data-test='library-picker-caret']") |> render_click()
    view |> element("#discover-configure-add") |> render_click()

    assert has_element?(view, "#add-config-form button[type=submit][disabled]")
    assert render(view) =~ "No library paths"
  end
end
