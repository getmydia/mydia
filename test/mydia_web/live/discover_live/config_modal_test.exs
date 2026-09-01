defmodule MydiaWeb.DiscoverLive.ConfigModalTest do
  # async: false — connected LiveView tests cannot use the Postgres
  # non-shared sandbox, which hides test rows from the mount process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    # DiscoverLive.Index unconditionally loads the movie genre list on
    # connected mount (#530), and the plain `/discover` mount (no search
    # query) falls into the default :trending category.
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])

    provider_id = unique_provider_id()

    warm_movie_search_cache("quiet harbour", [], [
      %{"id" => provider_id, "title" => "Quiet Harbour", "release_date" => "2024-05-01"}
    ])

    user = user_fixture(%{role: "admin"})
    library_path_fixture(%{type: :movies})
    quality_profile_fixture()

    %{conn: log_in_user(conn, user), provider_id: provider_id}
  end

  test "the modal is closed on mount", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")

    refute has_element?(view, "#add-config-modal[open]")
  end

  # Reaching Configure requires opening the library-picker caret first: the
  # entry lives inside library_picker_dialog/1 (a single page-level element,
  # so its DOM id cannot repeat per card), and that dialog only renders once
  # @picker is set. With only one candidate library the caret would normally
  # stay hidden (library_picker_button/1's `> 1` gate), so DiscoverLive marks
  # its caret always_show_caret: true — Configure must stay reachable
  # regardless of how many libraries exist, including zero.
  test "the configure entry opens the modal seeded with resolved defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

    view |> element("[data-test='library-picker-caret']") |> render_click()
    view |> element("#discover-configure-add") |> render_click()

    assert has_element?(view, "#add-config-modal[open]")
    assert has_element?(view, "#add-config-form select[name='config[library_path_id]']")
    assert has_element?(view, "#add-config-form select[name='config[quality_profile_id]']")
    # A movie has no seasons: the season monitoring select is guarded on
    # @media_type == :tv_show and must not render here.
    refute has_element?(view, "#add-config-form select[name='config[season_monitoring]']")
    assert has_element?(view, "#add-config-form input[name='config[monitored]'][type=checkbox]")

    assert has_element?(
             view,
             "#add-config-form input[name='config[search_on_add]'][type=checkbox]"
           )
  end

  test "closing the modal leaves nothing added", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

    view |> element("[data-test='library-picker-caret']") |> render_click()
    view |> element("#discover-configure-add") |> render_click()
    view |> element("#add-config-modal button", "Cancel") |> render_click()

    refute has_element?(view, "#add-config-modal[open]")
    assert Mydia.Media.list_media_items() == []
  end
end
