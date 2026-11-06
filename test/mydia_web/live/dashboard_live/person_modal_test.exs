defmodule MydiaWeb.DashboardLive.PersonModalTest do
  @moduledoc """
  The person popup on the Dashboard: opened from a cast member in the title dialog,
  with the person's posters opening the title dialog on top of it.

  Every relay route is served by one Bypass, pointed at with the global relay
  URL, so this file cannot run async.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubHelpers
  import Mydia.SettingsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Accounts
  alias Mydia.Media.MediaItem
  alias Mydia.Media.MediaRequest
  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias Mydia.Repo

  @person_name "Odalys Wren"

  setup do
    warm_genre_cache(:movie, [])
    warm_genre_cache(:tv_show, [])
    warm_trending_cache(:tv_show, [])
    :ok
  end

  describe "from the title dialog" do
    setup %{conn: conn} do
      title_id = unique_provider_id()
      warm_trending_cache(:movie, [%{"id" => title_id, "title" => "Lantern Ward"}])

      bypass = point_relay_at_bypass()
      person_id = unique_person_id()
      movie_id = unique_provider_id()
      show_id = unique_provider_id()

      stub_movie(bypass, title_id, "Lantern Ward",
        cast: [%{"id" => person_id, "name" => @person_name, "character" => "Lead"}]
      )

      stub_movie(bypass, movie_id, "Glass Orchard")
      stub_show(bypass, show_id, "Tidewater Bureau")

      stub_person(
        bypass,
        person_id,
        [movie_credit(movie_id, "Glass Orchard")] ++
          [tv_credit(show_id, "Tidewater Bureau")]
      )

      %{
        conn: log_in_user(conn, create_admin_user()),
        title_id: title_id,
        person_id: person_id,
        movie_id: movie_id,
        show_id: show_id
      }
    end

    test "a cast member replaces the title dialog with the person popup", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/")

      view
      |> element("div[phx-click='show_details'][phx-value-id='#{ctx.title_id}']")
      |> render_click()

      assert has_element?(view, "#trending-detail-modal[open]")
      render_async(view)
      assert has_element?(view, "#cast-person-#{ctx.person_id}-0")

      view |> element("#cast-person-#{ctx.person_id}-0") |> render_click()

      assert has_element?(view, "#person-modal[open]")
      refute has_element?(view, "#trending-detail-modal[open]")

      render_async(view)

      assert has_element?(view, "#person-modal-name", @person_name)
      assert has_element?(view, "#person-credit-movie-#{ctx.movie_id}")
      assert has_element?(view, "#person-credit-tv_show-#{ctx.show_id}")
    end

    test "a poster opens the title dialog over the person, and closing it keeps the person",
         ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/")
      open_person(view, ctx.person_id)

      view |> element("#person-credit-movie-#{ctx.movie_id}") |> render_click()

      assert has_element?(view, "#trending-detail-modal[open]")
      assert has_element?(view, "#trending-detail-modal h2", "Glass Orchard")
      assert has_element?(view, "#person-modal[open]")

      render_click(view, "close_details", %{})

      refute has_element?(view, "#trending-detail-modal[open]")
      assert has_element?(view, "#person-modal[open]")
      assert has_element?(view, "#person-credit-movie-#{ctx.movie_id}")
    end

    test "close_person shuts the popup", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/")
      open_person(view, ctx.person_id)

      view |> element("#person-modal-close") |> render_click()

      refute has_element?(view, "#person-modal[open]")
    end
  end

  test "a show poster opens the show when a movie credit shares its TMDB id", %{conn: conn} do
    warm_trending_cache(:movie, [])
    bypass = point_relay_at_bypass()
    person_id = unique_person_id()
    shared_id = unique_provider_id()

    stub_show(bypass, shared_id, "Tidewater Bureau")

    stub_person(bypass, person_id, [
      movie_credit(shared_id, "Glass Orchard"),
      tv_credit(shared_id, "Tidewater Bureau")
    ])

    {:ok, view, _html} = live(log_in_user(conn, create_admin_user()), ~p"/")
    open_person(view, person_id)

    view |> element("#person-credit-tv_show-#{shared_id}") |> render_click()

    # The header title comes from the fetched show metadata either way; the add
    # button is built from the selected item itself, so it shows which title
    # the click resolved to.
    assert has_element?(view, "#trending-detail-modal h2", "Tidewater Bureau")

    assert has_element?(
             view,
             "#trending-detail-modal button[phx-click='add_to_library'][phx-value-media_type='tv_show']"
           )

    refute has_element?(view, "#trending-detail-modal button[phx-value-media_type='movie']")
  end

  test "a show poster opens the TMDB show, not a TVDB shelf show sharing its id", %{conn: conn} do
    register_shelf_plugin!()
    user = create_admin_user()
    {:ok, _} = Accounts.put_home_widgets(user, [:shelves])
    now = DateTime.utc_now()
    shelf = shelf_fixture(user, filled_at: now, stale_at: DateTime.add(now, 3_600))

    bypass = point_relay_at_bypass()
    person_id = unique_person_id()
    shared_id = unique_provider_id()

    shelf_item_fixture(shelf, %{
      media_type: :tv_show,
      provider: :tvdb,
      provider_id: shared_id,
      title: "Harbor Decoy"
    })

    stub_show(bypass, shared_id, "Tidewater Bureau")
    stub_person(bypass, person_id, [tv_credit(shared_id, "Tidewater Bureau")])

    # Answered at once, so a click that wrongly resolves to the shelf show fails
    # the assertion below instead of waiting out Req's retries.
    Bypass.stub(bypass, "GET", "/tvdb/series/#{shared_id}/extended", fn conn ->
      json(conn, 404, %{})
    end)

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")
    open_person(view, person_id)

    view |> element("#person-credit-tv_show-#{shared_id}") |> render_click()

    selected = :sys.get_state(view.pid).socket.assigns.selected_item
    assert %{provider: :tmdb, title: "Tidewater Bureau"} = selected
  end

  test "adding a movie credit marks its poster owned", %{conn: conn} do
    warm_trending_cache(:movie, [])
    library_path_fixture(%{type: "movies"})
    bypass = point_relay_at_bypass()
    person_id = unique_person_id()
    movie_id = unique_provider_id()

    stub_movie(bypass, movie_id, "Glass Orchard")
    stub_person(bypass, person_id, [movie_credit(movie_id, "Glass Orchard")])

    {:ok, view, _html} =
      live(log_in_user(conn, create_admin_user()), ~p"/")

    open_person(view, person_id)
    refute has_element?(view, "#person-credit-movie-#{movie_id} .badge-success")

    view |> element("#person-credit-movie-#{movie_id}") |> render_click()

    view
    |> element("#trending-detail-modal button[phx-click='add_to_library']")
    |> render_click()

    # The add runs in a handle_info queued by the click; a render waits for it.
    render(view)

    assert %MediaItem{} = Repo.get_by(MediaItem, tmdb_id: movie_id, type: "movie")
    assert has_element?(view, "#person-credit-movie-#{movie_id} .badge-success")
    assert has_element?(view, "#person-owned-count")
    refute has_element?(view, "#trending-detail-modal button[phx-click='add_to_library']")
  end

  test "a guest requests a TV credit opened from a person", %{conn: conn} do
    warm_trending_cache(:movie, [])
    bypass = point_relay_at_bypass()
    person_id = unique_person_id()
    show_id = unique_provider_id()

    stub_person(bypass, person_id, [tv_credit(show_id, "Tidewater Bureau")])

    {:ok, view, _html} = live(log_in_user(conn, user_fixture(%{role: "guest"})), ~p"/")
    open_person(view, person_id)

    render_click(view, "request_media", %{"ref" => "tmdb:#{show_id}", "media_type" => "tv_show"})
    render(view)

    assert %MediaRequest{media_type: "tv_show", title: "Tidewater Bureau"} =
             Repo.get_by(MediaRequest, tmdb_id: show_id)

    titles = :sys.get_state(view.pid).socket.assigns.person_titles
    assert [%{provider_id: provider_id, request_status: "pending"}] = titles
    assert provider_id == to_string(show_id)
  end

  @tag :capture_log
  test "a failed lookup names the person and Try again refetches", %{conn: conn} do
    warm_trending_cache(:movie, [])
    bypass = point_relay_at_bypass()
    person_id = unique_person_id()
    movie_id = unique_provider_id()
    calls = :counters.new(1, [])

    Bypass.stub(bypass, "GET", "/tmdb/person/#{person_id}", fn conn ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1 do
        json(conn, 404, %{})
      else
        json(conn, 200, person_body(person_id, [movie_credit(movie_id, "Glass Orchard")]))
      end
    end)

    {:ok, view, _html} = live(log_in_user(conn, create_admin_user()), ~p"/")
    render_click(view, "show_person", %{"id" => to_string(person_id), "name" => @person_name})
    render_async(view)

    assert has_element?(view, "#person-modal-error", @person_name)

    view |> element("#person-modal-retry") |> render_click()
    render_async(view)

    refute has_element?(view, "#person-modal-error")
    assert has_element?(view, "#person-credit-movie-#{movie_id}")
  end

  defp open_person(view, person_id) do
    render_click(view, "show_person", %{
      "id" => to_string(person_id),
      "name" => @person_name,
      "profile_path" => ""
    })

    render_async(view)
    assert has_element?(view, "#person-modal[open]")
  end

  defp unique_person_id do
    id = unique_provider_id()
    language = Metadata.default_relay_config().options.language
    on_exit(fn -> Cache.delete("person:metadata_relay:#{id}:#{language}") end)
    id
  end

  defp stub_person(bypass, person_id, credits) do
    Bypass.stub(bypass, "GET", "/tmdb/person/#{person_id}", fn conn ->
      json(conn, 200, person_body(person_id, credits))
    end)
  end

  defp person_body(person_id, credits) do
    %{
      "id" => person_id,
      "name" => @person_name,
      "biography" => "An invented performer.",
      "known_for_department" => "Acting",
      "profile_path" => nil,
      "combined_credits" => %{"cast" => credits}
    }
  end

  defp movie_credit(id, title) do
    %{
      "id" => id,
      "media_type" => "movie",
      "title" => title,
      "release_date" => "2021-04-02",
      "character" => "Lead",
      "genre_ids" => []
    }
  end

  defp tv_credit(id, name) do
    %{
      "id" => id,
      "media_type" => "tv",
      "name" => name,
      "first_air_date" => "2019-09-09",
      "character" => "Guest",
      "episode_count" => 3,
      "genre_ids" => []
    }
  end

  # Serves both the detail fetch and the recommendations fetch, which share the
  # movie route.
  defp stub_movie(bypass, id, title, opts \\ []) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      json(conn, 200, %{
        "id" => id,
        "title" => title,
        "release_date" => "2021-04-02",
        "overview" => "An invented film.",
        "genres" => [],
        "belongs_to_collection" => nil,
        "credits" => %{"cast" => Keyword.get(opts, :cast, []), "crew" => []},
        "videos" => %{"results" => []},
        "recommendations" => %{"page" => 1, "results" => [], "total_pages" => 1}
      })
    end)
  end

  defp stub_show(bypass, id, name) do
    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
      json(conn, 200, %{
        "id" => id,
        "name" => name,
        "first_air_date" => "2019-09-09",
        "overview" => "An invented series.",
        "genres" => [],
        "credits" => %{"cast" => [], "crew" => []},
        "videos" => %{"results" => []},
        "recommendations" => %{"page" => 1, "results" => [], "total_pages" => 1}
      })
    end)

    # A TMDB show's detail is resolved to TVDB metadata by title search; no
    # match keeps the TMDB metadata.
    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn -> json(conn, 200, %{"data" => []}) end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
