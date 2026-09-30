defmodule MydiaWeb.DashboardLive.RegionalWidgetTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Metadata.Cache

  setup %{conn: conn} do
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Cache.clear()

      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    user = create_admin_user()
    %{conn: log_in_user(conn, user), user: user, bypass: bypass}
  end

  defp set_prefs(user, prefs) do
    {:ok, _} =
      Accounts.update_preference(Accounts.get_user_preference!(user), %{"preferences" => prefs})
  end

  defp enable_widget(user),
    do: {:ok, _} = Accounts.put_home_widgets(user, Accounts.home_widgets(user) ++ [:regional])

  defp stub_discover(bypass) do
    test_pid = self()

    for {path, key, title, date_key, date} <- [
          {"/tmdb/movies/discover", "title", "Quiet Lanterns", "release_date", "2026-09-01"},
          {"/tmdb/tv/discover", "name", "The Tidewatch", "first_air_date", "2026-07-15"}
        ] do
      Bypass.stub(bypass, "GET", path, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:discover_query, path, conn.query_params})

        body = %{
          "page" => 1,
          "total_pages" => 1,
          "results" => [%{"id" => :erlang.phash2(title), key => title, date_key => date}]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)
    end
  end

  test "hidden by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#regional-widget")
  end

  test "no country: points to Discover", %{conn: conn, user: user} do
    enable_widget(user)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#regional-set-country[href='/discover']")
  end

  test "first chip loads cinemas; a service chip mixes movies and TV", %{
    conn: conn,
    user: user,
    bypass: bypass
  } do
    set_prefs(user, %{
      "discover_home_country" => "CA",
      "discover_streaming_services" => [%{"id" => 8001, "name" => "Maplestream"}]
    })

    enable_widget(user)
    stub_discover(bypass)

    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)

    assert has_element?(view, "#regional-widget", "In Canada")
    assert has_element?(view, "#regional-chip-in_cinemas.btn-primary")
    assert_received {:discover_query, "/tmdb/movies/discover", %{"region" => "CA"}}
    refute_received {:discover_query, "/tmdb/tv/discover", _}
    assert has_element?(view, "#regional-rail", "Quiet Lanterns")

    view |> element("#regional-chip-service-8001") |> render_click()
    render_async(view)

    assert has_element?(view, "#regional-rail", "Quiet Lanterns")
    assert has_element?(view, "#regional-rail", "The Tidewatch")
    assert has_element?(view, "#regional-view-all[href*='source=service-8001']")
  end

  test "a forged chip is ignored", %{conn: conn, user: user, bypass: bypass} do
    set_prefs(user, %{"discover_home_country" => "CA"})
    enable_widget(user)
    stub_discover(bypass)

    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)

    render_click(view, "select_regional_source", %{"source" => "service-424242"})

    assert has_element?(view, "#regional-chip-in_cinemas.btn-primary")
  end
end
