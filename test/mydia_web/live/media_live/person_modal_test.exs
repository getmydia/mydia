defmodule MydiaWeb.MediaLive.PersonModalTest do
  @moduledoc """
  The person popup on the movie/show page: opened from the page's own cast
  panel or from a cast member in the title dialog, with the person's posters
  opening the title dialog on top of it.

  The viewed movie has no TMDB id, so mounting the page asks the relay for
  nothing; every route the popup and the dialog need is served by one Bypass,
  pointed at with the global relay URL, so this file cannot run async.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Media.MediaRequest
  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.{CastMember, MediaMetadata}
  alias Mydia.Repo

  @person_name "Odalys Wren"

  setup do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})
    :ok
  end

  describe "the page's cast panel" do
    test "a linked actor opens the person popup; an unlinked one has no button", %{conn: conn} do
      bypass = point_relay_at_bypass()
      person_id = unique_person_id()
      movie_id = unique_provider_id()

      stub_person(bypass, person_id, [movie_credit(movie_id, "Glass Orchard")])

      movie =
        viewed_movie([
          %CastMember{name: @person_name, character: "Lead", tmdb_person_id: person_id},
          %CastMember{name: "Brannoc Teale", character: "Ferryman", tmdb_person_id: nil}
        ])

      {:ok, view, _html} = live(log_in_user(conn, create_admin_user()), ~p"/media/#{movie.id}")

      assert has_element?(view, "#media-cast-person-#{person_id}")
      refute has_element?(view, "button[phx-click='show_person']", "Brannoc Teale")
      assert has_element?(view, "[data-tip]", "Brannoc Teale")

      view |> element("#media-cast-person-#{person_id}") |> render_click()
      assert has_element?(view, "#person-modal[open]")

      render_async(view)

      assert has_element?(view, "#person-modal-name", @person_name)
      assert has_element?(view, "#person-credit-movie-#{movie_id}")

      view |> element("#person-modal-close") |> render_click()
      refute has_element?(view, "#person-modal[open]")
    end

    test "the page's cast and the title dialog's cast can show one actor without duplicate ids",
         %{conn: conn} do
      bypass = point_relay_at_bypass()
      person_id = unique_person_id()
      movie_id = unique_provider_id()

      stub_movie(bypass, movie_id, "Glass Orchard",
        cast: [%{"id" => person_id, "name" => @person_name, "character" => "Lead"}]
      )

      stub_person(bypass, person_id, [movie_credit(movie_id, "Glass Orchard")])

      movie =
        viewed_movie([
          %CastMember{name: @person_name, character: "Lead", tmdb_person_id: person_id}
        ])

      {:ok, view, _html} = live(log_in_user(conn, create_admin_user()), ~p"/media/#{movie.id}")
      open_person(view, person_id)

      view |> element("#person-credit-movie-#{movie_id}") |> render_click()
      wait_until(fn -> has_element?(view, "#media-detail-modal #cast-person-#{person_id}") end)

      document = view |> render() |> LazyHTML.from_fragment()
      assert document |> LazyHTML.query("#media-cast-person-#{person_id}") |> Enum.count() == 1
      assert document |> LazyHTML.query("#cast-person-#{person_id}") |> Enum.count() == 1
    end
  end

  describe "a person opened on a movie's page" do
    test "a show poster opens the show when a movie credit shares its TMDB id", %{conn: conn} do
      bypass = point_relay_at_bypass()
      person_id = unique_person_id()
      shared_id = unique_provider_id()

      stub_show(bypass, shared_id, "Tidewater Bureau")

      stub_person(bypass, person_id, [
        movie_credit(shared_id, "Glass Orchard"),
        tv_credit(shared_id, "Tidewater Bureau")
      ])

      movie = viewed_movie()

      {:ok, view, _html} = live(log_in_user(conn, create_admin_user()), ~p"/media/#{movie.id}")
      open_person(view, person_id)

      view |> element("#person-credit-tv_show-#{shared_id}") |> render_click()

      assert has_element?(view, "#media-detail-modal h2", "Tidewater Bureau")

      assert has_element?(
               view,
               "#media-detail-modal button[phx-click='add_selected_item'][phx-value-media_type='tv_show']"
             )

      refute has_element?(view, "#media-detail-modal button[phx-value-media_type='movie']")
    end

    test "Add on a TV credit adds a show, not a movie", %{conn: conn} do
      library_path_fixture(%{type: "mixed"})
      bypass = point_relay_at_bypass()
      person_id = unique_person_id()
      show_id = unique_provider_id()

      stub_show(bypass, show_id, "Tidewater Bureau")
      stub_person(bypass, person_id, [tv_credit(show_id, "Tidewater Bureau")])

      movie_profile = quality_profile_fixture()

      movie =
        viewed_movie()
        |> Ecto.Changeset.change(quality_profile_id: movie_profile.id, monitored: false)
        |> Repo.update!()

      {:ok, view, _html} = live(log_in_user(conn, create_admin_user()), ~p"/media/#{movie.id}")
      open_person(view, person_id)

      view |> element("#person-credit-tv_show-#{show_id}") |> render_click()

      view
      |> element("#media-detail-modal button[phx-click='add_selected_item']")
      |> render_click()

      render_async(view, 5000)

      assert %MediaItem{} = show = Repo.get_by(MediaItem, tmdb_id: show_id, type: "tv_show")
      refute Repo.get_by(MediaItem, tmdb_id: show_id, type: "movie")

      # A show takes the TV add defaults, not the viewed movie's settings.
      refute show.quality_profile_id == movie_profile.id
      assert show.monitored

      # The person's poster gains its owned badge.
      assert has_element?(view, "#person-credit-tv_show-#{show_id} .badge-success")
    end

    test "the configure dialog adds a TV credit as a show", %{conn: conn} do
      library_path_fixture(%{type: "mixed"})
      bypass = point_relay_at_bypass()
      person_id = unique_person_id()
      show_id = unique_provider_id()

      stub_show(bypass, show_id, "Tidewater Bureau")
      stub_person(bypass, person_id, [tv_credit(show_id, "Tidewater Bureau")])

      movie = viewed_movie()

      {:ok, view, _html} = live(log_in_user(conn, create_admin_user()), ~p"/media/#{movie.id}")
      open_person(view, person_id)

      view |> element("#person-credit-tv_show-#{show_id}") |> render_click()

      render_click(view, "open_add_config", %{
        "ref" => "tmdb:#{show_id}",
        "media_type" => "tv_show",
        "title" => "Tidewater Bureau"
      })

      render_click(view, "submit_add_config", %{"config" => %{"monitored" => "true"}})
      render_async(view, 5000)

      assert %MediaItem{} = Repo.get_by(MediaItem, tmdb_id: show_id, type: "tv_show")
      refute Repo.get_by(MediaItem, tmdb_id: show_id, type: "movie")
    end

    test "a guest's Request on a TV credit is recorded as a show", %{conn: conn} do
      bypass = point_relay_at_bypass()
      person_id = unique_person_id()
      show_id = unique_provider_id()

      stub_show(bypass, show_id, "Tidewater Bureau")
      stub_person(bypass, person_id, [tv_credit(show_id, "Tidewater Bureau")])

      movie = viewed_movie()

      {:ok, view, _html} =
        live(log_in_user(conn, user_fixture(%{role: "guest"})), ~p"/media/#{movie.id}")

      open_person(view, person_id)

      view |> element("#person-credit-tv_show-#{show_id}") |> render_click()

      view
      |> element("#media-detail-modal button[phx-click='request_selected_item']")
      |> render_click()

      assert %MediaRequest{media_type: "tv_show", title: "Tidewater Bureau"} =
               Repo.get_by(MediaRequest, tmdb_id: show_id)

      titles = :sys.get_state(view.pid).socket.assigns.person_titles
      assert [%{provider_id: provider_id, request_status: "pending"}] = titles
      assert provider_id == to_string(show_id)
    end
  end

  defp viewed_movie(cast \\ []) do
    media_item_fixture(%{
      type: "movie",
      title: "Harrow Lane",
      year: 2021,
      metadata: %MediaMetadata{
        provider_id: "1",
        provider: :tmdb,
        media_type: :movie,
        cast: cast
      }
    })
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
      json(conn, 200, %{
        "id" => person_id,
        "name" => @person_name,
        "biography" => "An invented performer.",
        "known_for_department" => "Acting",
        "profile_path" => nil,
        "combined_credits" => %{"cast" => credits}
      })
    end)
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
  defp stub_movie(bypass, id, title, opts) do
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
        "seasons" => [],
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
end
