defmodule MydiaWeb.MediaLive.FixMatchTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.MetadataStub
  import Mydia.MetadataCacheHelpers, only: [warm_recommendations_cache: 3]

  test "opens the fix match search for an operator who may delete media", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", year: 2001})

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")
    view |> element("#fix-match-button") |> render_click()

    assert has_element?(view, "#fix-match-modal")
    assert has_element?(view, "#fix-match-search-form input[value='Wrong Pick']")
  end

  test "a guest cannot open it", %{conn: conn} do
    {conn, _guest} = register_and_log_in_user(conn, %{role: "guest"})
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", year: 2001})

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")
    render_click(view, "open_fix_match", %{})

    refute has_element?(view, "#fix-match-modal")
  end

  describe "TV provider toggle" do
    setup :setup_metadata_stub

    defp show_in_tvdb_library(attrs) do
      library = library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})
      item = media_item_fixture(Map.merge(%{type: "tv_show", title: "Lantern Harbor"}, attrs))
      episode = episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})
      media_file_fixture(%{episode_id: episode.id, library_path_id: library.id})
      item
    end

    test "a show offers the toggle, a movie does not", %{conn: conn} do
      {conn, _user} = register_and_log_in_user(conn)
      show = show_in_tvdb_library(%{metadata_source: :tvdb})

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
      view |> element("#fix-match-button") |> render_click()
      assert has_element?(view, "#fix-match-provider-toggle")
      assert has_element?(view, "#fix-match-provider-tvdb[checked]")

      movie = media_item_fixture(%{type: "movie", title: "Paper Kite", year: 2001})
      {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
      view |> element("#fix-match-button") |> render_click()
      refute has_element?(view, "#fix-match-provider-toggle")
    end

    test "picking a TMDB result switches and pins the show", %{conn: conn} do
      {conn, _user} = register_and_log_in_user(conn)
      show = show_in_tvdb_library(%{metadata_source: :tvdb})

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
      view |> element("#fix-match-button") |> render_click()
      view |> element("#fix-match-provider-tmdb") |> render_click()

      view
      |> form("#fix-match-search-form", fix_match: %{query: "Lantern Harbor"})
      |> render_submit()

      render_async(view)
      tmdb_id = Mydia.MetadataStubProvider.series_tmdb_id()
      warm_recommendations_cache(tmdb_id, :tv_show, [])
      render_click(view, "fix_match_pick", %{"provider_id" => to_string(tmdb_id)})
      render_click(view, "fix_match_confirm", %{})
      assert_redirect(view, ~p"/media/#{show.id}", 2000)

      item = Mydia.Repo.get!(Mydia.Media.MediaItem, show.id)
      assert item.metadata_source == :tmdb
      assert item.metadata_source_pinned

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
      assert has_element?(view, "#metadata-source-pinned-badge")
    end

    # The stub catalog has a TVDB series (series_tvdb_id) and a TMDB series
    # (series_tmdb_id). Storing the show's TMDB id as the TVDB series' number
    # makes a TVDB result share its numeric id with the show's current match.
    defp tmdb_show_with_tmdb_id(tmdb_id) do
      library = library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Lantern Harbor",
          tmdb_id: tmdb_id,
          metadata_source: :tmdb
        })

      episode = episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})
      media_file_fixture(%{episode_id: episode.id, library_path_id: library.id})
      warm_recommendations_cache(tmdb_id, :tv_show, [])
      item
    end

    defp search_fix_match(conn, show, provider) do
      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
      view |> element("#fix-match-button") |> render_click()
      view |> element("#fix-match-provider-#{provider}") |> render_click()

      view
      |> form("#fix-match-search-form", fix_match: %{query: "Lantern Harbor"})
      |> render_submit()

      render_async(view)
      view
    end

    test "a result on the other provider sharing the current id stays pickable", %{conn: conn} do
      {conn, _user} = register_and_log_in_user(conn)
      shared_id = Mydia.MetadataStubProvider.series_tvdb_id()
      show = tmdb_show_with_tmdb_id(shared_id)

      view = search_fix_match(conn, show, "tvdb")

      assert has_element?(view, "#fix-match-candidate-#{shared_id}")
      refute has_element?(view, "#fix-match-candidate-#{shared_id}[disabled]")
      refute has_element?(view, "#fix-match-candidate-#{shared_id}", "Current match")
    end

    test "the matching result on the current provider is disabled", %{conn: conn} do
      {conn, _user} = register_and_log_in_user(conn)
      current = Mydia.MetadataStubProvider.series_tmdb_id()
      show = tmdb_show_with_tmdb_id(current)

      view = search_fix_match(conn, show, "tmdb")

      assert has_element?(view, "#fix-match-candidate-#{current}[disabled]")
      assert has_element?(view, "#fix-match-candidate-#{current}", "Current match")
    end
  end
end
