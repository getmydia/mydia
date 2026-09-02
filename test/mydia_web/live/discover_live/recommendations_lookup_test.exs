defmodule MydiaWeb.DiscoverLive.RecommendationsLookupTest do
  @moduledoc """
  Covers the widened `show_details` lookup, and the recommendations rail that
  fetch feeds.

  A recommendation is not part of the current grid page, so resolving the click
  against `items` alone silently drops it and the modal never swaps. That failure
  is invisible in the UI, which is why it gets a direct test.

  The rail also gets a rendering test, unlike the rest of Discover (see the
  header of library_picker_test.exs for why those stay unit-only): Discover
  routes every TV search to TVDB, so a TV search result's own ref can never
  reach TMDB's recommendations route. The only way to prove the rail still
  populates when TMDB does know the show is to drive the real handle_info
  sequence -- open the modal, let the detail metadata resolve, and check what
  the rail did with the cross-reference it carried.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers
  import Mydia.SettingsFixtures

  alias MydiaWeb.DiscoverLive.Index

  defp result(provider_id), do: %{provider_id: provider_id, title: "Title #{provider_id}"}

  test "finds an item on the current grid page" do
    items = [result("1"), result("2")]

    assert %{provider_id: "2"} = Index.find_selectable_item(items, [], "2")
  end

  test "finds an item that exists only in the recommendations rail" do
    recommendations = [result("101")]

    assert %{provider_id: "101"} = Index.find_selectable_item([], recommendations, "101")
  end

  test "prefers the grid item when both lists carry the id" do
    grid = %{provider_id: "5", title: "From grid"}
    rail = %{provider_id: "5", title: "From rail"}

    assert %{title: "From grid"} = Index.find_selectable_item([grid], [rail], "5")
  end

  test "returns nil for an unknown id" do
    assert is_nil(Index.find_selectable_item([result("1")], [result("101")], "999"))
  end

  describe "the recommendations rail for a TVDB-sourced show" do
    setup %{conn: conn} do
      # Warmed before the env swap below, and fully self-contained (its own
      # bypass, its own save/restore): DiscoverLive.mount always loads the
      # movie... no, the *current* media_type's genre list, which for a
      # ?type=tv_show mount is tv_show's.
      warm_genre_cache(:tv_show, [])

      bypass = Bypass.open()
      previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_metadata_relay_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      library_path_fixture(%{type: :series})

      tvdb_id = unique_provider_id()

      Bypass.expect_once(bypass, "GET", "/tvdb/search", fn conn ->
        body = %{
          "data" => [
            %{
              "tvdb_id" => tvdb_id,
              "name" => "Harbor Signal",
              "year" => "2019",
              "overview" => "A stub series used by the recommendations rail tests.",
              "first_air_time" => "2019-05-01"
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      %{conn: log_in_user(conn, create_admin_user()), bypass: bypass, tvdb_id: tvdb_id}
    end

    # The defect this proves fixed: every Discover TV search result carries a
    # TVDB id (Relay.search/3 routes :tv_show to TVDB), so sending that id
    # straight to TMDB's recommendations route always 404s. Once the detail
    # metadata resolves, DiscoverLive derives the TMDB cross-reference from
    # its external_ids and the rail should populate from that instead.
    test "populates once the detail metadata resolves a TMDB cross-reference", %{
      conn: conn,
      bypass: bypass,
      tvdb_id: tvdb_id
    } do
      tmdb_id = unique_provider_id()
      recommended_id = unique_provider_id()

      Bypass.expect_once(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        body = tvdb_extended_body(tvdb_id, remote_ids: [tmdb_remote_id(tmdb_id)])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      warm_recommendations_cache(tmdb_id, :tv_show, [
        %{"id" => recommended_id, "name" => "Second Signal", "first_air_date" => "2020-02-02"}
      ])

      # The query text embeds tvdb_id so this test's search never reads a
      # `search_cached/3` entry left behind by the sibling test below: both
      # tests search for a title with this same literal prefix, but each
      # picks a fresh unique_provider_id/0, and search_cached/3 keys its
      # cache on the query string.
      {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&q=harbor-#{tvdb_id}")

      view
      |> element("div[phx-click='show_details'][phx-value-id='#{tvdb_id}']")
      |> render_click()

      assert has_element?(view, "#discover-detail-modal[open]")

      wait_until(fn ->
        has_element?(view, "#discover-recommendations-rail-item-#{recommended_id}")
      end)
    end

    # The other half: a TVDB show TMDB does not cross-reference must neither
    # populate the rail from a wrong id nor call TMDB at all. No stub is
    # registered for the TMDB route on this bypass, so an errant call fails
    # the test on its own rather than needing an explicit assertion.
    test "stays empty and calls TMDB nothing when the metadata carries no cross-reference", %{
      conn: conn,
      bypass: bypass,
      tvdb_id: tvdb_id
    } do
      Bypass.expect_once(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        body = tvdb_extended_body(tvdb_id, remote_ids: [])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&q=harbor-#{tvdb_id}")

      view
      |> element("div[phx-click='show_details'][phx-value-id='#{tvdb_id}']")
      |> render_click()

      assert has_element?(view, "#discover-detail-modal[open]")

      wait_until(fn -> loading_spinner_gone?(view) end)

      refute has_element?(view, "#discover-recommendations-rail")
    end
  end

  # `trailers` carries a real entry so `Relay`'s TVDB metadata parsing never
  # falls back to a TMDB videos lookup, which would otherwise need its own
  # bypass stub on this same path regardless of what this test is actually
  # proving.
  defp tvdb_extended_body(tvdb_id, opts) do
    %{
      "data" => %{
        "id" => tvdb_id,
        "name" => "Harbor Signal",
        "overview" => "A stub series used by the recommendations rail tests.",
        "first_air_date" => "2019-05-01",
        "genres" => [],
        "seasons" => [],
        "trailers" => [
          %{
            "id" => 1,
            "name" => "Trailer",
            "url" => "https://youtu.be/abc123",
            "language" => "eng"
          }
        ],
        "remoteIds" => Keyword.fetch!(opts, :remote_ids)
      }
    }
  end

  defp tmdb_remote_id(tmdb_id),
    do: %{"sourceName" => "TheMovieDB.com", "id" => to_string(tmdb_id)}

  # `handle_info({:fetch_detail_metadata, ...})` blocks the LiveView process
  # on its own HTTP call, and (when it resolves a cross-reference) queues the
  # recommendations fetch as a follow-up message rather than starting it
  # inline -- see the comment on that clause in index.ex. Neither step is
  # tracked by LiveView's own async subsystem the way `render_async/2` is, so
  # polling is what proves the sequence has actually settled rather than
  # merely not-yet-run.
  defp wait_until(fun, retries \\ 200)

  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end

  defp loading_spinner_gone?(view),
    do: not has_element?(view, "#trending-detail-modal-body .loading-spinner")
end
