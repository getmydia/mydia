defmodule MydiaWeb.DiscoverLive.RegionalRowsTest do
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

    warm_genre_cache(:movie, [])
    warm_genre_cache(:tv_show, [])
    warm_trending_cache(:movie, [])

    user = create_admin_user()

    {:ok, _} =
      Accounts.update_preference(Accounts.get_user_preference!(user), %{
        "preferences" => %{
          "discover_home_country" => "CA",
          "discover_streaming_services" => [%{"id" => 8001, "name" => "Maplestream"}]
        }
      })

    %{conn: log_in_user(conn, user), user: user, bypass: bypass}
  end

  defp stub_movie_details(bypass) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/:id", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 1, "title" => "Stub", "overview" => ""}))
    end)
  end

  # One stub for both discover endpoints. The title names which source asked,
  # so each row's contents prove its query.
  defp stub_discover(bypass, opts \\ []) do
    test_pid = self()
    fail = Keyword.get(opts, :fail, fn _ -> false end)

    for path <- ["/tmdb/movies/discover", "/tmdb/tv/discover"] do
      Bypass.stub(bypass, "GET", path, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        q = conn.query_params
        send(test_pid, {:discover_query, path, q})

        if fail.(q) do
          Plug.Conn.resp(conn, 500, "{}")
        else
          title =
            cond do
              q["with_release_type"] && q["sort_by"] == "primary_release_date.asc" ->
                "Soon Lantern"

              q["with_release_type"] ->
                "Cinema Lantern"

              q["with_watch_providers"] ->
                "Maple Lantern"

              q["with_origin_country"] ->
                "Homegrown Lantern"

              true ->
                "Other Lantern"
            end

          body = %{
            "page" => 1,
            "total_pages" => 1,
            "results" => [%{"id" => :erlang.phash2(title), "title" => title, "name" => title}]
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(body))
        end
      end)
    end
  end

  test "movies: one row per source, in order", %{conn: conn, bypass: bypass} do
    stub_discover(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
    render_async(view)

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#discover-regional-rows > [id^='discover-row-']")
      |> Enum.map(&(LazyHTML.attribute(&1, "id") |> hd()))

    assert ids == [
             "discover-row-in_cinemas",
             "discover-row-coming_soon",
             "discover-row-service-8001",
             "discover-row-made_here"
           ]

    assert has_element?(view, "#discover-row-in_cinemas", "Cinema Lantern")
    assert has_element?(view, "#discover-row-coming_soon", "Soon Lantern")
    assert has_element?(view, "#discover-row-service-8001", "Latest on Maplestream")
    assert has_element?(view, "#discover-row-service-8001", "Maple Lantern")
    assert has_element?(view, "#discover-row-made_here", "Made in Canada")
    refute has_element?(view, "#discover-filter-form")
    refute has_element?(view, "#discover-grid")
  end

  test "rows send the regional params", %{conn: conn, bypass: bypass} do
    stub_discover(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
    render_async(view)

    assert_received {:discover_query, "/tmdb/movies/discover",
                     %{"region" => "CA", "with_release_type" => "2|3"}}

    assert_received {:discover_query, "/tmdb/movies/discover",
                     %{
                       "watch_region" => "CA",
                       "with_watch_providers" => "8001",
                       "with_watch_monetization_types" => "flatrate"
                     }}
  end

  test "tv drops the cinema rows", %{conn: conn, bypass: bypass} do
    stub_discover(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&category=home")
    render_async(view)

    refute has_element?(view, "#discover-row-in_cinemas")
    refute has_element?(view, "#discover-row-coming_soon")
    assert has_element?(view, "#discover-row-service-8001", "Maple Lantern")
  end

  test "a failed row shows a retry and the others still render", %{conn: conn, bypass: bypass} do
    stub_discover(bypass, fail: &(&1["with_watch_providers"] == "8001"))

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
    render_async(view, 20_000)

    assert has_element?(view, "#discover-row-service-8001-retry")
    assert has_element?(view, "#discover-row-in_cinemas", "Cinema Lantern")
  end

  test "no services: the prompt replaces the service rows", %{
    conn: conn,
    user: user,
    bypass: bypass
  } do
    {:ok, _} =
      Accounts.update_preference(Accounts.get_user_preference!(user), %{
        "preferences" => %{"discover_streaming_services" => []}
      })

    stub_discover(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
    render_async(view)

    assert has_element?(view, "#discover-services-prompt")
    refute has_element?(view, "[id^='discover-row-service-']")
  end

  test "a row title opens the detail modal", %{conn: conn, bypass: bypass} do
    stub_discover(bypass)
    stub_movie_details(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
    render_async(view)

    id = to_string(:erlang.phash2("Maple Lantern"))
    render_click(view, "show_details", %{"id" => id, "type" => "movie"})

    assert has_element?(view, "#discover-detail-modal")
  end
end
