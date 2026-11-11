defmodule MydiaWeb.DiscoverLive.SortAndTabsTest do
  @moduledoc """
  The Custom tab's sort reaches TMDB with a key the media type's discover
  endpoint understands, and the list tabs leave the custom filters behind
  (#1381).
  """

  # async: false: connected LiveView tests cannot use the Postgres
  # non-shared sandbox, and the relay URL is global config.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Metadata.Cache

  setup %{conn: conn} do
    # Discover results are cached by their options, so a cached page from an
    # earlier test would hide the request this test asserts on.
    Cache.clear()
    warm_genre_cache(:tv_show, [])
    warm_genre_cache(:movie, [])

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

    test_pid = self()

    for path <- ~w(/tmdb/tv/discover /tmdb/movies/discover /tmdb/tv/trending) do
      Bypass.stub(bypass, "GET", path, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:relay, path, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
      end)
    end

    user = user_fixture(%{role: "admin"})
    %{conn: log_in_user(conn, user)}
  end

  defp discover_sort(path) do
    assert_receive {:relay, ^path, params}
    params["sort_by"]
  end

  describe "sorting by date" do
    test "TV Newest First sorts by first air date", %{conn: conn} do
      {:ok, _view, _html} =
        live(conn, ~p"/discover?type=tv_show&category=discover&sort=first_air_date.desc")

      assert discover_sort("/tmdb/tv/discover") == "first_air_date.desc"
    end

    test "TV offers first air date sorts and no movie release date sorts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&category=discover")

      assert has_element?(view, "select[name=sort] option[value='first_air_date.desc']")
      assert has_element?(view, "select[name=sort] option[value='first_air_date.asc']")
      refute has_element?(view, "select[name=sort] option[value='primary_release_date.desc']")
    end

    test "a movie date sort on TV falls back to the default", %{conn: conn} do
      {:ok, _view, _html} =
        live(conn, ~p"/discover?type=tv_show&category=discover&sort=primary_release_date.desc")

      assert discover_sort("/tmdb/tv/discover") == "popularity.desc"
    end

    test "movies keep sorting by release date", %{conn: conn} do
      {:ok, _view, _html} =
        live(conn, ~p"/discover?type=movie&category=discover&sort=primary_release_date.asc")

      assert discover_sort("/tmdb/movies/discover") == "primary_release_date.asc"
    end
  end

  describe "switching tabs" do
    test "a list tab drops the custom filters", %{conn: conn} do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/discover?type=tv_show&category=discover&genre=18&rating=7&sort=first_air_date.desc"
        )

      view
      |> element("[phx-click=switch_category][phx-value-category=trending]")
      |> render_click()

      assert_patch(view, ~p"/discover?type=tv_show")
      assert has_element?(view, "[phx-value-category=trending].tab-active")
    end
  end
end
