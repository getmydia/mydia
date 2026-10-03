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
    render_async(view, 5_000)

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#discover-regional-rows > [id^='discover-row-']")
      |> Enum.map(&(LazyHTML.attribute(&1, "id") |> hd()))

    assert ids == [
             "discover-row-in_cinemas",
             "discover-row-coming_soon",
             "discover-row-service-8001"
           ]

    assert has_element?(view, "#discover-row-in_cinemas", "Cinema Lantern")
    assert has_element?(view, "#discover-row-coming_soon", "Soon Lantern")
    assert has_element?(view, "#discover-row-service-8001", "Latest on Maplestream")
    assert has_element?(view, "#discover-row-service-8001", "Maple Lantern")
    refute has_element?(view, "#discover-filter-form")
    refute has_element?(view, "#discover-grid")
  end

  test "rows send the regional params", %{conn: conn, bypass: bypass} do
    stub_discover(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
    render_async(view, 5_000)

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
    render_async(view, 5_000)

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

  test "no services: the prompt sits above the cinema rows", %{
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
    render_async(view, 5_000)

    assert has_element?(view, "#discover-regional-rows > #discover-services-prompt:first-child")
    assert has_element?(view, "#discover-row-in_cinemas")
    refute has_element?(view, "[id^='discover-row-service-']")
  end

  test "tv with no services shows only the prompt", %{conn: conn, user: user, bypass: bypass} do
    {:ok, _} =
      Accounts.update_preference(Accounts.get_user_preference!(user), %{
        "preferences" => %{"discover_streaming_services" => []}
      })

    stub_discover(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&category=home")
    render_async(view, 5_000)

    assert has_element?(view, "#discover-services-prompt")
    refute has_element?(view, "[id^='discover-row-']")
  end

  test "a row title opens the detail modal", %{conn: conn, bypass: bypass} do
    stub_discover(bypass)
    stub_movie_details(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
    render_async(view, 5_000)

    id = to_string(:erlang.phash2("Maple Lantern"))
    render_click(view, "show_details", %{"id" => id, "type" => "movie"})

    assert has_element?(view, "#discover-detail-modal")
  end

  describe "See all" do
    test "opens the grid for one source with the filter bar", %{conn: conn, bypass: bypass} do
      stub_discover(bypass)

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home&source=service-8001")

      assert_receive {:discover_query, "/tmdb/movies/discover",
                      %{
                        "with_watch_providers" => "8001",
                        "sort_by" => "primary_release_date.desc"
                      }}

      assert has_element?(view, "#discover-grid", "Maple Lantern")
      assert has_element?(view, "#discover-filter-form")
      assert has_element?(view, "#discover-see-all-title", "Latest on Maplestream")
      assert has_element?(view, "#discover-see-all-back")
    end

    test "the row's See all link patches there", %{conn: conn, bypass: bypass} do
      stub_discover(bypass)

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
      render_async(view, 5_000)

      view |> element("#discover-row-service-8001-see-all") |> render_click()

      assert_patch(
        view,
        ~p"/discover?#{%{"category" => "home", "source" => "service-8001", "type" => "movie"}}"
      )

      assert_receive {:discover_query, _, %{"with_watch_providers" => "8001"}}
    end

    test "filters keep the source and the source's sort", %{conn: conn, bypass: bypass} do
      stub_discover(bypass)

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home&source=service-8001")

      view
      |> element("#discover-filter-form")
      |> render_change(%{"language" => "fr", "sort" => "primary_release_date.desc"})

      assert_patch(
        view,
        ~p"/discover?#{%{"category" => "home", "language" => "fr", "source" => "service-8001", "type" => "movie"}}"
      )
    end

    test "picking popularity on a date-sorted source keeps it in the URL", %{
      conn: conn,
      bypass: bypass
    } do
      stub_discover(bypass)

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home&source=service-8001")

      view |> element("#discover-filter-form") |> render_change(%{"sort" => "popularity.desc"})

      assert_patch(
        view,
        ~p"/discover?#{%{"category" => "home", "sort" => "popularity.desc", "source" => "service-8001", "type" => "movie"}}"
      )
    end

    test "an unknown or unsaved source falls back to the rows", %{conn: conn, bypass: bypass} do
      stub_discover(bypass)

      for source <- ["service-9999", "bogus", "made_here"] do
        {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home&source=#{source}")
        assert has_element?(view, "#discover-regional-rows")
      end

      {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&category=home&source=in_cinemas")
      assert has_element?(view, "#discover-regional-rows")
    end

    test "the country tab returns from See all to the rows", %{conn: conn, bypass: bypass} do
      stub_discover(bypass)

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home&source=service-8001")

      view |> element("#discover-home-tab") |> render_click()

      assert_patch(view, ~p"/discover?#{%{"category" => "home", "type" => "movie"}}")
    end

    test "clearing filters stays on the See all grid", %{conn: conn, bypass: bypass} do
      stub_discover(bypass)

      {:ok, view, _html} =
        live(conn, ~p"/discover?type=movie&category=home&source=service-8001&language=fr")

      render_click(view, "clear_filters", %{})

      assert_patch(
        view,
        ~p"/discover?#{%{"category" => "home", "source" => "service-8001", "type" => "movie"}}"
      )
    end
  end

  describe "restricted accounts on See all" do
    test "certification params go out alongside the service", %{bypass: bypass} do
      stub_discover(bypass)

      # The age limit makes the filter look the title up; serve it from cache.
      for type <- [:movie, :tv_show] do
        warm_remote_signals(
          {:tmdb, :erlang.phash2("Maple Lantern")},
          type,
          %Mydia.Media.RemoteSignals{
            content_rating: "PG",
            age: 8,
            category: "movie"
          }
        )
      end

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
          source: {:service, 8001, "Maplestream"},
          default_sort: "primary_release_date.desc",
          regional_rows: %{},
          selected_genres: [],
          selected_language: nil,
          selected_year: nil,
          min_rating: nil,
          sort_by: "primary_release_date.desc",
          current_scope: %Mydia.Accounts.Scope{
            Mydia.Accounts.Scope.unrestricted()
            | max_content_age: 12
          }
        }
      }

      {:noreply, _updated} = MydiaWeb.DiscoverLive.Index.handle_info(:load_data, socket)

      assert_receive {:discover_query, "/tmdb/movies/discover",
                      %{
                        "with_watch_providers" => "8001",
                        "certification_country" => "US",
                        "certification.lte" => "PG"
                      }}
    end
  end
end
