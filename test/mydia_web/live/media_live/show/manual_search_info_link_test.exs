defmodule MydiaWeb.MediaLive.Show.ManualSearchInfoLinkTest do
  # async: false — disables and creates indexer configs, which is process-wide
  # state (same reasoning as ManualSearchQualityGateTest).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.IndexerMock
  alias Mydia.Settings

  @info_url "https://tracker.example/details/42"

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  # NOTE: movie_result/1 builds a fixed map and does NOT forward an :info_url
  # key, so `movie_result(%{info_url: ...})` silently does nothing and the
  # IndexerMock default ("https://example.com") applies. The key has to be put
  # on the returned map, which is what build_search_result/1 reads.
  defp result_with_info_url(info_url) do
    IndexerMock.movie_result(%{title: "The Matrix", year: 1999})
    |> Map.put(:info_url, info_url)
  end

  defp open_manual_search(conn, results) do
    Settings.list_indexer_configs()
    |> Enum.reject(&Settings.runtime_config?/1)
    |> Enum.each(&Settings.update_indexer_config(&1, %{enabled: false}))

    bypass = Bypass.open()
    IndexerMock.mock_prowlarr_all(bypass, results: results)

    {:ok, _indexer} =
      Settings.create_indexer_config(%{
        name: "Test Movie Indexer",
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "test-key",
        enabled: true
      })

    movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    render_click(view, "manual_search", %{})
    render_async(view)

    assert has_element?(view, "#manual-search-results")

    view
  end

  test "links the indexer badge to the release page when info_url is usable", %{conn: conn} do
    view = open_manual_search(conn, [result_with_info_url(@info_url)])

    assert has_element?(view, ~s(#manual-search-results a[href="#{@info_url}"]))

    assert has_element?(
             view,
             ~s(#manual-search-results a[target="_blank"][rel="noopener noreferrer"])
           )
  end

  test "renders no link when the indexer supplies no info_url", %{conn: conn} do
    view = open_manual_search(conn, [result_with_info_url(nil)])

    refute has_element?(view, "#manual-search-results a[href]")
  end

  test "refuses to render a javascript: info_url as a link", %{conn: conn} do
    view = open_manual_search(conn, [result_with_info_url("javascript:alert(1)")])

    refute has_element?(view, "#manual-search-results a[href]")
    refute render(view) =~ "javascript:alert(1)"
  end
end
