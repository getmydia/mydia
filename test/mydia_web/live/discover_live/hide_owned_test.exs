defmodule MydiaWeb.DiscoverLive.HideOwnedTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.DiscoverLive.Index

  describe "the toggle" do
    setup %{conn: conn} do
      # DiscoverLive.Index unconditionally loads the movie genre list on
      # connected mount (#530).
      warm_genre_cache(:movie, [])
      warm_trending_cache(:movie, [])

      user = create_admin_user()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "the toggle renders and starts off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-hide-owned")
      refute has_element?(view, "#discover-hide-owned[checked]")
    end

    test "toggling persists to the user preference", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-hide-owned") |> render_click()

      pref = Accounts.get_user_preference!(user)
      assert UserPreference.discover_hide_owned(pref) == true
    end

    test "the preference is honoured on the next mount", %{conn: conn, user: user} do
      pref = Accounts.get_user_preference!(user)

      {:ok, _} =
        Accounts.update_preference(pref, %{"preferences" => %{"discover_hide_owned" => true}})

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-hide-owned[checked]")
    end
  end

  describe "filtering the grid" do
    setup %{conn: conn} do
      warm_genre_cache(:movie, [])

      user = create_admin_user()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "with the toggle off, an owned title stays in the grid", %{conn: conn} do
      owned_id = unique_provider_id()
      unowned_id = unique_provider_id()
      insert(:media_item, tmdb_id: owned_id, type: "movie")

      warm_trending_cache(:movie, [
        %{"id" => owned_id, "title" => "Marooned Aurora"},
        %{"id" => unowned_id, "title" => "Paper Comet"}
      ])

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-grid h3", "Marooned Aurora")
      assert has_element?(view, "#discover-grid h3", "Paper Comet")
    end

    test "with the toggle on, the owned title is hidden and the rest remain", %{conn: conn} do
      owned_id = unique_provider_id()
      unowned_id = unique_provider_id()
      insert(:media_item, tmdb_id: owned_id, type: "movie")

      warm_trending_cache(:movie, [
        %{"id" => owned_id, "title" => "Marooned Aurora"},
        %{"id" => unowned_id, "title" => "Paper Comet"}
      ])

      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-hide-owned") |> render_click()

      refute has_element?(view, "#discover-grid h3", "Marooned Aurora")
      assert has_element?(view, "#discover-grid h3", "Paper Comet")
    end

    test "toggling on advances past a fully-owned page instead of stranding the user",
         %{conn: conn} do
      owned_id = unique_provider_id()
      visible_id = unique_provider_id()
      insert(:media_item, tmdb_id: owned_id, type: "movie")

      # warm_trending_cache/2 hardcodes total_pages: 1, which would always
      # leave has_more false. This needs page 1 to report more pages so
      # toggling the filter on has something to auto-advance into.
      bypass = Bypass.open()
      previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_metadata_relay_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      # Unlike warm_trending_cache/2, this hits the real fetch path for two
      # pages, and Metadata.fetch_curated_list/2 caches whatever it fetches.
      # Left behind, "curated:trending:movie:2" in particular would leak this
      # test's items into any later test in this file that fetches page 2.
      on_exit(fn ->
        Cache.delete("curated:trending:movie:1")
        Cache.delete("curated:trending:movie:2")
      end)

      Bypass.expect(bypass, "GET", "/tmdb/movies/trending", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        body =
          case conn.query_params["page"] do
            "2" ->
              %{
                "page" => 2,
                "total_pages" => 2,
                "total_results" => 1,
                "results" => [%{"id" => visible_id, "title" => "Paper Comet"}]
              }

            _ ->
              %{
                "page" => 1,
                "total_pages" => 2,
                "total_results" => 1,
                "results" => [%{"id" => owned_id, "title" => "Marooned Aurora"}]
              }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-hide-owned") |> render_click()

      wait_until(fn -> has_element?(view, "#discover-grid h3", "Paper Comet") end)

      refute has_element?(view, "#discover-grid h3", "Marooned Aurora")
    end

    test "adding a title while the toggle is on removes its card from the grid", %{conn: conn} do
      addable_id = unique_provider_id()
      keeper_id = unique_provider_id()

      warm_trending_cache(:movie, [
        %{"id" => addable_id, "title" => "Glass Horizon"},
        %{"id" => keeper_id, "title" => "Velvet Static"}
      ])

      # The add flow's metadata fetch (Add.from_provider -> Metadata.fetch_by_ref)
      # is uncached, unlike the curated-list lookups above, so it needs its own
      # Bypass and a temporary metadata_relay_url swap rather than a cache warm.
      bypass = Bypass.open()
      previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_metadata_relay_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{addable_id}", fn conn ->
        body = %{
          "id" => addable_id,
          "title" => "Glass Horizon",
          "release_date" => "2020-01-01",
          "belongs_to_collection" => nil
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-hide-owned") |> render_click()

      assert has_element?(view, "#discover-grid h3", "Glass Horizon")

      view
      |> element("button[phx-click='add_to_library'][phx-value-ref='tmdb:#{addable_id}']")
      |> render_click()

      wait_until(fn -> not has_element?(view, "#discover-grid h3", "Glass Horizon") end)

      assert has_element?(view, "#discover-grid h3", "Velvet Static")
    end
  end

  # Exercises maybe_auto_advance/2's decision logic directly through the
  # public handle_info/2 clauses that call it, without a connected LiveView.
  # Driving this scenario through `live/2` would mean waiting on a `send(self(),
  # ...)` message the LiveView process schedules for itself mid-render, which
  # Phoenix.LiveViewTest has no built-in way to await deterministically. Calling
  # handle_info/2 straight from the test process sidesteps that: any
  # `send(self(), ...)` it triggers lands in this test's own mailbox, so the
  # three-fetch bound can be asserted with assert_received/refute_received
  # instead of a polling loop.
  describe "auto-advance" do
    test "fetches the next page when a fully-owned page leaves the grid empty" do
      owned_id = unique_provider_id()
      visible_id = unique_provider_id()

      seed_curated_page(1, 2, [curated_result(owned_id, "Marooned Aurora")])
      seed_curated_page(2, 2, [curated_result(visible_id, "Paper Comet")])

      library_status_map = %{
        owned_id => %{in_library: true, monitored: true, type: "movie", id: "owned"}
      }

      socket = curated_socket(%{library_status_map: library_status_map})

      {:noreply, socket} = Index.handle_info(:load_data, socket)

      assert_received {:load_page, 2, 1}
      assert socket.assigns.visible_items == []
      assert socket.assigns.loading_more == true

      {:noreply, socket} = Index.handle_info({:load_page, 2, 1}, socket)

      refute_received {:load_page, _page, _advances}
      assert [%{title: "Paper Comet"}] = socket.assigns.visible_items
      assert socket.assigns.loading_more == false
    end

    test "gives up after three fetches so a fully-owned category cannot spin forever" do
      owned_id = unique_provider_id()

      for page <- 1..4 do
        seed_curated_page(page, 5, [curated_result(owned_id, "Endless Owned #{page}")])
      end

      library_status_map = %{
        owned_id => %{in_library: true, monitored: true, type: "movie", id: "owned"}
      }

      socket = curated_socket(%{library_status_map: library_status_map})

      {:noreply, socket} = Index.handle_info(:load_data, socket)
      assert_received {:load_page, 2, 1}

      {:noreply, socket} = Index.handle_info({:load_page, 2, 1}, socket)
      assert_received {:load_page, 3, 2}

      {:noreply, socket} = Index.handle_info({:load_page, 3, 2}, socket)
      assert_received {:load_page, 4, 3}

      {:noreply, socket} = Index.handle_info({:load_page, 4, 3}, socket)
      refute_received {:load_page, _page, _advances}

      # Still owned, still more pages available: the bound stopped it, not the
      # data running out.
      assert socket.assigns.visible_items == []
      assert socket.assigns.has_more == true
      assert socket.assigns.loading_more == false
    end
  end

  defp curated_socket(overrides) do
    base = %{
      __changed__: %{},
      flash: %{},
      media_type: :movie,
      search_mode: false,
      search_query: "",
      category: :trending,
      page: 1,
      items: [],
      visible_items: [],
      has_more: true,
      hide_owned: true,
      library_status_map: %{},
      request_status_map: %{},
      loading_more: false
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, overrides)}
  end

  defp seed_curated_page(page, total_pages, results) do
    key = "curated:trending:movie:#{page}"

    Cache.put(key, %{results: results, page: page, total_pages: total_pages},
      ttl: :timer.minutes(30)
    )

    on_exit(fn -> Cache.delete(key) end)
  end

  defp curated_result(id, title) do
    SearchResult.from_api_response(%{"id" => id, "title" => title}, media_type: :movie)
  end

  # A local retry loop, not a shared helper: the add flow's async completion
  # (handle_info({:add_media_to_library, ...})) has no built-in
  # Phoenix.LiveViewTest wait, so this polls the rendered view until the
  # owned card's card disappears or gives up.
  defp wait_until(fun, retries \\ 200)

  defp wait_until(_fun, 0) do
    flunk("condition not met in time")
  end

  defp wait_until(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end
end
