defmodule MydiaWeb.SearchLive.InfoLinkTest do
  # async: false — disables and creates indexer configs, which is process-wide
  # state (same reasoning as ManualSearchQualityGateTest).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.IndexerMock
  alias Mydia.Settings

  @info_url "https://tracker.example/details/42"
  @magnet "magnet:?xt=urn:btih:" <> String.duplicate("a", 40)

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  # movie_result/1 randomizes :magnet_url and ignores :info_url, so both are
  # overridden on the returned map, which is what build_search_result/1 reads.
  # The predictable magnet is needed to trigger "show_detail", whose handler
  # looks the result up by download_url in search_results_map.
  defp result_with_info_url(info_url) do
    IndexerMock.movie_result(%{title: "The Matrix", year: 1999})
    |> Map.put(:info_url, info_url)
    |> Map.put(:magnet_url, @magnet)
  end

  defp search_page(conn, results) do
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

    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> form("#indexer-search-form", %{"search" => "The Matrix"})
    |> render_submit()

    render_async(view)

    assert has_element?(view, "#search-results")

    view
  end

  test "links the indexer badge in the Source column when info_url is usable", %{conn: conn} do
    view = search_page(conn, [result_with_info_url(@info_url)])

    assert has_element?(view, ~s(#search-results a[href="#{@info_url}"]))

    assert has_element?(
             view,
             ~s(#search-results a[target="_blank"][rel="noopener noreferrer"])
           )
  end

  test "renders no link in the Source column when info_url is missing", %{conn: conn} do
    view = search_page(conn, [result_with_info_url(nil)])

    refute has_element?(view, "#search-results a[href]")
  end

  test "refuses to render a javascript: info_url as a link", %{conn: conn} do
    view = search_page(conn, [result_with_info_url("javascript:alert(1)")])

    refute has_element?(view, "#search-results a[href]")
    refute render(view) =~ "javascript:alert(1)"
  end

  test "links the Source badge in the detail modal", %{conn: conn} do
    view = search_page(conn, [result_with_info_url(@info_url)])

    render_click(view, "show_detail", %{"download_url" => @magnet})

    assert has_element?(view, ~s(a[href="#{@info_url}"]))
  end
end
