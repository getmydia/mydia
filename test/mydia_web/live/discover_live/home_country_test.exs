defmodule MydiaWeb.DiscoverLive.HomeCountryTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.Scope
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata.Cache
  alias MydiaWeb.DiscoverLive.Index

  setup %{conn: conn} do
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      # Metadata.discover/2 caches whatever the stub returns; clear it so no
      # test's results leak into the next.
      Cache.clear()

      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    # DiscoverLive.Index loads the movie genre list on connected mount, and
    # the default tab is Trending.
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])

    user = create_admin_user()
    %{conn: log_in_user(conn, user), user: user, bypass: bypass}
  end

  # Stubs the movie discover endpoint and reports every query it receives.
  # `results_for_page` maps a page number to `{results, total_pages}`.
  defp stub_discover(
         bypass,
         results_for_page \\ fn _page ->
           {[%{"id" => 424_242, "title" => "Frostbound Ferry"}], 1}
         end
       ) do
    test_pid = self()

    Bypass.stub(bypass, "GET", "/tmdb/movies/discover", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:discover_query, conn.query_params})
      page = String.to_integer(conn.query_params["page"] || "1")
      {results, total_pages} = results_for_page.(page)
      body = %{"page" => page, "total_pages" => total_pages, "results" => results}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    Bypass.stub(bypass, "GET", "/tmdb/tv/discover", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"page" => 1, "total_pages" => 1, "results" => []}))
    end)
  end

  defp home_country(user),
    do: user |> Accounts.get_user_preference!() |> UserPreference.discover_home_country()

  describe "the removed country filter" do
    test "a ?country= link is ignored", %{conn: conn, user: user, bypass: bypass} do
      stub_discover(bypass)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/discover?#{%{"type" => "movie", "category" => "discover", "country" => "CA"}}"
        )

      assert_receive {:discover_query, q}
      refute Map.has_key?(q, "with_origin_country")
      refute has_element?(view, "#discover-filter-form select[name='country']")
      assert home_country(user) == nil
    end

    test "?country= alone does not switch to Custom", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover?#{%{"type" => "movie", "country" => "CA"}}")

      refute has_element?(view, "#discover-filter-form")
      assert has_element?(view, "[role='tab'].tab-active", "Trending")
    end
  end

  defp set_home_country(user, code) do
    pref = Accounts.get_user_preference!(user)

    {:ok, _} =
      Accounts.update_preference(pref, %{"preferences" => %{"discover_home_country" => code}})
  end

  describe "the home country tab" do
    test "with no preference there is no tab, only the add control", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      refute has_element?(view, "#discover-home-tab")
      assert has_element?(view, "#discover-home-country-add")
    end

    test "a forged or blank country is ignored", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-home-country-add") |> render_click()

      for code <- ["XX", ""] do
        view
        |> element("#discover-home-country-picker")
        |> render_change(%{"country" => code})
      end

      assert home_country(user) == nil
      refute has_element?(view, "#discover-home-tab")
      assert has_element?(view, "#discover-home-country-picker")
    end

    test "picking a country saves it and opens its tab", %{conn: conn, user: user, bypass: bypass} do
      stub_discover(bypass)
      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-home-country-add") |> render_click()
      assert has_element?(view, "#discover-home-country-picker")

      view
      |> element("#discover-home-country-picker")
      |> render_change(%{"country" => "CA"})

      assert_patch(view, ~p"/discover?#{%{"category" => "home", "type" => "movie"}}")
      assert home_country(user) == "CA"
      assert has_element?(view, "#discover-home-tab.tab-active", "Canada")
      refute has_element?(view, "#discover-home-country-picker")
      render_async(view)
      assert has_element?(view, "#discover-regional-rows")
    end

    test "the saved tab shows on the next mount", %{conn: conn, user: user} do
      set_home_country(user, "CA")

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-home-tab", "Canada")
      refute has_element?(view, "#discover-home-tab.tab-active")
      refute has_element?(view, "#discover-home-country-add")
    end

    test "removing the tab clears the preference", %{conn: conn, user: user, bypass: bypass} do
      stub_discover(bypass)
      set_home_country(user, "CA")

      {:ok, view, _html} = live(conn, ~p"/discover?#{%{"type" => "movie", "category" => "home"}}")

      view |> element("#discover-home-country-remove") |> render_click()

      assert_patch(view, ~p"/discover?#{%{"type" => "movie"}}")
      assert home_country(user) == nil
      refute has_element?(view, "#discover-home-tab")
      assert has_element?(view, "#discover-home-country-add")
    end

    test "category=home with no preference falls back to Trending", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover?#{%{"type" => "movie", "category" => "home"}}")

      refute has_element?(view, "#discover-home-tab")
      assert has_element?(view, "[role='tab'].tab-active", "Trending")
      refute_received {:discover_query, _}
    end

    test "filters apply on a See all grid inside the tab", %{
      conn: conn,
      user: user,
      bypass: bypass
    } do
      stub_discover(bypass)
      set_home_country(user, "CA")

      {:ok, view, _html} =
        live(
          conn,
          ~p"/discover?#{%{"type" => "movie", "category" => "home", "source" => "in_cinemas", "language" => "fr"}}"
        )

      assert_receive {:discover_query, %{"region" => "CA", "with_original_language" => "fr"} = q}
      refute Map.has_key?(q, "with_origin_country")

      assert has_element?(view, "#discover-home-tab.tab-active")
      assert has_element?(view, "#discover-filter-form")
    end

    test "hide-owned auto-advance works on the tab", %{conn: conn, user: user, bypass: bypass} do
      owned_id = unique_provider_id()
      visible_id = unique_provider_id()
      insert(:media_item, tmdb_id: owned_id, type: "movie")
      set_home_country(user, "CA")

      pref = Accounts.get_user_preference!(user)

      {:ok, _} =
        Accounts.update_preference(pref, %{"preferences" => %{"discover_hide_owned" => true}})

      stub_discover(bypass, fn
        1 -> {[%{"id" => owned_id, "title" => "Marooned Aurora"}], 2}
        _ -> {[%{"id" => visible_id, "title" => "Paper Comet"}], 2}
      end)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/discover?#{%{"type" => "movie", "category" => "home", "source" => "in_cinemas"}}"
        )

      wait_until(fn -> has_element?(view, "#discover-grid h3", "Paper Comet") end)
      refute has_element?(view, "#discover-grid h3", "Marooned Aurora")
    end
  end

  describe "restricted accounts on the home tab" do
    test "certification params go out alongside the country", %{bypass: bypass} do
      stub_discover(bypass)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          library_status_map: %{},
          request_status_map: %{},
          selected_recommendations: [],
          selected_item: nil,
          hide_owned: false,
          visible_items: [],
          loading_more: false,
          items: [],
          page: 1,
          total_pages: 1,
          has_more: false,
          load_error: nil,
          loading: true,
          media_type: :movie,
          search_mode: false,
          search_query: "",
          category: :home,
          home_country: "CA",
          selected_genres: [],
          selected_language: nil,
          selected_year: nil,
          min_rating: nil,
          sort_by: "popularity.desc",
          source: :in_cinemas,
          default_sort: "popularity.desc",
          regional_rows: %{},
          current_scope: %Scope{Scope.unrestricted() | max_content_age: 12}
        }
      }

      {:noreply, _updated} = Index.handle_info(:load_data, socket)

      assert_receive {:discover_query,
                      %{
                        "region" => "CA",
                        "certification_country" => "US",
                        "certification.lte" => "PG"
                      }}
    end
  end

  defp wait_until(fun, retries \\ 200)

  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end
end
