defmodule MydiaWeb.DiscoverLive.HomeCountryTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata.Cache

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
  end

  defp home_country(user),
    do: user |> Accounts.get_user_preference!() |> UserPreference.discover_home_country()

  describe "the one-off country filter" do
    test "?country=CA filters by origin and saves nothing", %{
      conn: conn,
      user: user,
      bypass: bypass
    } do
      stub_discover(bypass)

      {:ok, view, _html} = live(conn, ~p"/discover?#{%{"type" => "movie", "country" => "CA"}}")

      assert_receive {:discover_query, %{"with_origin_country" => "CA"}}
      assert has_element?(view, "#discover-grid h3", "Frostbound Ferry")

      assert has_element?(
               view,
               "#discover-filter-form select[name='country'] option[value='CA'][selected]"
             )

      assert home_country(user) == nil
    end

    test "an unknown ?country= is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover?#{%{"type" => "movie", "country" => "XX"}}")

      refute has_element?(view, "#discover-filter-form")
      refute_received {:discover_query, _}
    end

    test "picking a country in the filter bar patches the URL", %{conn: conn, bypass: bypass} do
      stub_discover(bypass)

      {:ok, view, _html} =
        live(conn, ~p"/discover?#{%{"type" => "movie", "category" => "discover"}}")

      view
      |> element("#discover-filter-form")
      |> render_change(%{"country" => "CA"})

      assert_patch(
        view,
        ~p"/discover?#{%{"category" => "discover", "country" => "CA", "type" => "movie"}}"
      )
    end
  end
end
