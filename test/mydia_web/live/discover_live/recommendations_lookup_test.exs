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

  describe "the recommendations rail across a card switch" do
    # Only the pieces every test in this block needs: the bypass, the env
    # swap, and card A's own search-and-detail path. Card B's endpoints are
    # registered per-test instead of here, because `Bypass.expect_once/4`
    # fails the test if the endpoint it names is never called, and the
    # close-modal test below never opens card B.
    setup %{conn: conn} do
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

      tvdb_id_a = unique_provider_id()
      tvdb_id_b = unique_provider_id()
      tmdb_id_a = unique_provider_id()
      tmdb_id_b = unique_provider_id()

      Bypass.expect_once(bypass, "GET", "/tvdb/search", fn conn ->
        body = %{
          "data" => [
            tvdb_search_entry(tvdb_id_a, "Signal A"),
            tvdb_search_entry(tvdb_id_b, "Signal B")
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      Bypass.expect_once(bypass, "GET", "/tvdb/series/#{tvdb_id_a}/extended", fn conn ->
        body =
          tvdb_extended_body(tvdb_id_a, name: "Signal A", remote_ids: [tmdb_remote_id(tmdb_id_a)])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      %{
        conn: log_in_user(conn, create_admin_user()),
        bypass: bypass,
        tvdb_id_a: tvdb_id_a,
        tvdb_id_b: tvdb_id_b,
        tmdb_id_a: tmdb_id_a,
        tmdb_id_b: tmdb_id_b
      }
    end

    # The staleness guard this proves: `apply_recommendations/3` in index.ex
    # compares the fetch's target ref against whatever is currently selected
    # before assigning `:selected_recommendations`. Getting a *late* result
    # deterministically (rather than by luck or a sleep) needs A's
    # recommendations fetch to still be in flight when B is opened, so its
    # Bypass handler parks on a `receive` -- the same trick
    # `MetadataStubProvider.block_next_season_fetch/1` uses for seasons --
    # until this test explicitly releases it, well after B's own rail has
    # already settled.
    test "a late result for a replaced card does not populate the rail", %{
      conn: conn,
      bypass: bypass,
      tvdb_id_a: tvdb_id_a,
      tvdb_id_b: tvdb_id_b,
      tmdb_id_a: tmdb_id_a,
      tmdb_id_b: tmdb_id_b
    } do
      Bypass.expect_once(bypass, "GET", "/tvdb/series/#{tvdb_id_b}/extended", fn conn ->
        body =
          tvdb_extended_body(tvdb_id_b, name: "Signal B", remote_ids: [tmdb_remote_id(tmdb_id_b)])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      recommended_b_id = unique_provider_id()

      warm_recommendations_cache(tmdb_id_b, :tv_show, [
        %{"id" => recommended_b_id, "name" => "Second Signal B", "first_air_date" => "2021-03-03"}
      ])

      test_pid = self()
      recommended_a_id = unique_provider_id()

      Bypass.expect_once(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id_a}", fn conn ->
        send(test_pid, {:recommendations_a_fetch_started, self()})

        receive do
          :release_recommendations_a -> :ok
        after
          5_000 ->
            raise "timed out waiting for the test to release item A's recommendations fetch"
        end

        body = %{
          "id" => tmdb_id_a,
          "name" => "Signal A",
          "recommendations" => %{
            "page" => 1,
            "results" => [%{"id" => recommended_a_id, "name" => "Second Signal A"}],
            "total_pages" => 1,
            "total_results" => 1
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&q=signal-#{tvdb_id_a}")

      view
      |> element("div[phx-click='show_details'][phx-value-id='#{tvdb_id_a}']")
      |> render_click()

      assert has_element?(view, "#discover-detail-modal[open]")

      from_pid =
        receive do
          {:recommendations_a_fetch_started, pid} -> pid
        after
          5_000 -> flunk("item A's recommendations fetch never started")
        end

      # Switch to card B while A's fetch is still parked in the Bypass
      # handler above.
      view
      |> element("div[phx-click='show_details'][phx-value-id='#{tvdb_id_b}']")
      |> render_click()

      wait_until(fn ->
        has_element?(view, "#discover-recommendations-rail-item-#{recommended_b_id}")
      end)

      # Only now let A's fetch complete, well after B is selected and its own
      # rail has already rendered.
      send(from_pid, :release_recommendations_a)

      # There is no positive signal to poll for here -- the point of this
      # assertion is that nothing changes -- so give A's result every real
      # opportunity to land before checking.
      Process.sleep(200)
      render(view)

      assert has_element?(view, "#discover-recommendations-rail-item-#{recommended_b_id}"),
             "B's own recommendation must still be showing"

      refute has_element?(view, "#discover-recommendations-rail-item-#{recommended_a_id}"),
             "A's late-arriving result must not have populated B's rail"
    end

    # The other half of the same guard: `current_item_ref/1`'s `selected_item:
    # nil` clause must not raise when a result lands after the modal is
    # closed, and closing must not leave the view unresponsive. The template
    # already hides the rail whenever `@selected_item` is nil regardless of
    # `@selected_recommendations`, so there is no reopened-card DOM state to
    # assert against here the way the test above has -- this covers the crash
    # risk in the guard itself, not a second visible symptom.
    test "closing the modal while a fetch is in flight does not crash when it lands", %{
      conn: conn,
      bypass: bypass,
      tvdb_id_a: tvdb_id_a,
      tmdb_id_a: tmdb_id_a
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id_a}", fn conn ->
        send(test_pid, {:recommendations_a_fetch_started, self()})

        receive do
          :release_recommendations_a -> :ok
        after
          5_000 ->
            raise "timed out waiting for the test to release item A's recommendations fetch"
        end

        body = %{
          "id" => tmdb_id_a,
          "name" => "Signal A",
          "recommendations" => %{
            "page" => 1,
            "results" => [%{"id" => unique_provider_id(), "name" => "Second Signal A"}],
            "total_pages" => 1,
            "total_results" => 1
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&q=signal-#{tvdb_id_a}")

      view
      |> element("div[phx-click='show_details'][phx-value-id='#{tvdb_id_a}']")
      |> render_click()

      assert has_element?(view, "#discover-detail-modal[open]")

      from_pid =
        receive do
          {:recommendations_a_fetch_started, pid} -> pid
        after
          5_000 -> flunk("item A's recommendations fetch never started")
        end

      render_click(view, "close_details", %{})
      refute has_element?(view, "#discover-detail-modal[open]")

      send(from_pid, :release_recommendations_a)

      Process.sleep(200)

      # The assertion is that this does not crash: a late result landing
      # after close must not raise inside handle_async (current_item_ref/1's
      # nil clause) or leave the LiveView process dead.
      assert has_element?(view, "#discover-detail-modal")
      refute has_element?(view, "#discover-detail-modal[open]")
    end
  end

  defp tvdb_search_entry(tvdb_id, name) do
    %{
      "tvdb_id" => tvdb_id,
      "name" => name,
      "year" => "2019",
      "overview" => "A stub series used by the recommendations rail tests.",
      "first_air_time" => "2019-05-01"
    }
  end

  # `trailers` carries a real entry so `Relay`'s TVDB metadata parsing never
  # falls back to a TMDB videos lookup, which would otherwise need its own
  # bypass stub on this same path regardless of what this test is actually
  # proving.
  defp tvdb_extended_body(tvdb_id, opts) do
    %{
      "data" => %{
        "id" => tvdb_id,
        "name" => Keyword.get(opts, :name, "Harbor Signal"),
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
