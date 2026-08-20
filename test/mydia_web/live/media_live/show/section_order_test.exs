defmodule MydiaWeb.MediaLive.Show.SectionOrderTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only shared
  # with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache

  # Every section whose position this page decides. Each case asserts the whole
  # list rather than a pairwise precedence, so a section that stops rendering
  # fails the test instead of passing quietly.
  @sections "#seasons-episodes-section, #media-files-section, #subtitles-section, " <>
              "#timeline-section, #franchise-section, #recommendations-rail"

  # Provider ids here are offset past this floor rather than taken raw from
  # System.unique_integer/1, which hands out small positive integers. Those
  # collide two ways: with real TMDB ids, so any lookup this file forgets to stub
  # would reach the live relay, and with the many hardcoded ids elsewhere in the
  # suite, which share the same ETS-backed metadata cache and its keys. Real TMDB
  # ids are seven digits, and no fixture in the suite reaches nine, so everything
  # above this floor belongs to this file alone.
  @provider_id_floor 900_000_000

  setup %{conn: conn} do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # recommendations load can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "a movie renders its own files above the recommendations rail", %{conn: conn} do
    source_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Aftersun",
        year: 2022,
        tmdb_id: source_tmdb_id
      })

    media_file_fixture(%{media_item_id: movie.id})

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{
        "id" => unique_provider_id(),
        "title" => "The Eternal Daughter",
        "release_date" => "2022-12-02",
        "poster_path" => "/p.jpg"
      }
    ])

    warm_movie_details_cache(source_tmdb_id)

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    # timeline-section is here without seeding an event: media_item_fixture goes
    # through Media.create_media_item/2, which records media_item.added, and
    # Events.create_event_async/1 writes synchronously under the SQL sandbox.
    assert section_ids(view) == [
             "media-files-section",
             "subtitles-section",
             "timeline-section",
             "recommendations-rail"
           ]
  end

  test "a tv show keeps the rail above its episode list", %{conn: conn} do
    source_tmdb_id = unique_provider_id()

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Detectorists",
        year: 2014,
        tmdb_id: source_tmdb_id
      })

    episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    warm_recommendations_cache(source_tmdb_id, :tv_show, [
      %{
        "id" => unique_provider_id(),
        "name" => "Rev.",
        "first_air_date" => "2010-06-28",
        "poster_path" => "/p.jpg"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    # No media-files-section or subtitles-section: a show's files hang off its
    # episodes, so media_item.media_files is always empty here and both cards
    # guard themselves out.
    assert section_ids(view) == [
             "recommendations-rail",
             "seasons-episodes-section",
             "timeline-section"
           ]
  end

  test "a movie with a franchise renders both rails below its own files", %{conn: conn} do
    collection_id = unique_provider_id()
    owned_tmdb_id = unique_provider_id()
    missing_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "First",
        year: 2001,
        tmdb_id: owned_tmdb_id,
        metadata: %{
          "provider_id" => to_string(owned_tmdb_id),
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "First",
          "collection_id" => collection_id,
          "collection_name" => "Test Collection"
        }
      })

    media_file_fixture(%{media_item_id: movie.id})

    warm_collection_cache(collection_id, [
      %{"id" => owned_tmdb_id, "title" => "First", "release_date" => "2001-01-01"},
      %{"id" => missing_tmdb_id, "title" => "Second", "release_date" => "2004-01-01"}
    ])

    warm_recommendations_cache(owned_tmdb_id, :movie, [
      %{
        "id" => unique_provider_id(),
        "title" => "Third",
        "release_date" => "2010-01-01",
        "poster_path" => "/p.jpg"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert section_ids(view) == [
             "media-files-section",
             "subtitles-section",
             "timeline-section",
             "franchise-section",
             "recommendations-rail"
           ]
  end

  # A movie with no file is not left untouched by this reorder: its timeline card
  # moved above the rails along with the file and subtitle cards. That is the
  # intended grouping - everything about this copy of the movie, then everything
  # about other movies - and it holds even when the history is the only thing in
  # the first group. Pinned here so the placement stays a decision rather than a
  # side effect of the guards.
  test "a movie with no media files keeps its history above the rails", %{conn: conn} do
    source_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Unowned",
        year: 2019,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{
        "id" => unique_provider_id(),
        "title" => "Something Else",
        "release_date" => "2019-05-01",
        "poster_path" => "/p.jpg"
      }
    ])

    warm_movie_details_cache(source_tmdb_id)

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    # No media-files-section or subtitles-section: both guard on a non-empty
    # media_files. No franchise-section: the fixture carries no collection_id.
    assert section_ids(view) == [
             "timeline-section",
             "recommendations-rail"
           ]
  end

  defp unique_provider_id, do: @provider_id_floor + System.unique_integer([:positive])

  # LazyHTML.query/2, not filter/2: filter matches root nodes only, and these
  # cards are nested inside the layout. query returns matches in document order,
  # which is the whole point of the assertion.
  defp section_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(@sections)
    |> LazyHTML.attribute("id")
  end

  # Populates the shared metadata cache through the real fetch path, with the
  # relay response coming from Bypass. The cache key does not include the base
  # URL, so the LiveView's own default config reads this entry back without any
  # outbound request.
  defp warm_recommendations_cache(tmdb_id, media_type, results) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    on_exit(fn ->
      Cache.delete(
        "recommendations:#{relay.type}:#{tmdb_id}:#{media_type}:#{relay.options.language}"
      )
    end)

    path =
      if media_type == :tv_show, do: "/tmdb/tv/shows/#{tmdb_id}", else: "/tmdb/movies/#{tmdb_id}"

    Bypass.expect_once(bypass, "GET", path, fn conn ->
      body = %{
        "id" => tmdb_id,
        "title" => "Source",
        "recommendations" => %{
          "page" => 1,
          "results" => results,
          "total_pages" => 1,
          "total_results" => length(results)
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _results} =
      Metadata.fetch_recommendations_cached(config, to_string(tmdb_id), media_type: media_type)

    :ok
  end

  # Any movie whose metadata carries no collection_id sends
  # Franchises.resolve_collection_id/2 down a movie-details lookup, and that has
  # its own cache key ("fetch_by_id:...") entirely separate from the
  # recommendations one warmed above. Left unwarmed the lookup escapes to the
  # real relay, and System.unique_integer/1 hands out small integers that collide
  # with real TMDB movie ids: a movie that turns out to belong to a real
  # collection sprouts a franchise strip and reorders the page under the test.
  # Warming it with a collection-less payload makes the lookup resolve to :none
  # offline, so these assertions depend on nothing but the fixtures.
  defp warm_movie_details_cache(tmdb_id) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    # Mirrors the key fetch_by_id_cached/3 builds for these opts: no
    # append_to_response, so that segment is empty, and a nil season order
    # normalises to "official".
    on_exit(fn ->
      Cache.delete(
        "fetch_by_id:#{relay.type}:#{tmdb_id}:movie:#{relay.options.language}::official"
      )
    end)

    Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      body = %{"id" => tmdb_id, "title" => "Source", "belongs_to_collection" => nil}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _details} = Metadata.fetch_by_id_cached(config, to_string(tmdb_id), media_type: :movie)

    :ok
  end

  # Same trick as warm_recommendations_cache/3, for the TMDB collection lookup
  # behind the franchise strip. fetch_collection_cached/3 keys on the provider
  # type, collection id and language but not the base URL, so the LiveView reads
  # this entry back through its own default config with no outbound request.
  defp warm_collection_cache(collection_id, parts) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    on_exit(fn ->
      Cache.delete("collection:#{relay.type}:#{collection_id}:#{relay.options.language}")
    end)

    Bypass.expect_once(bypass, "GET", "/tmdb/collections/#{collection_id}", fn conn ->
      body = %{"id" => collection_id, "name" => "Test Collection", "parts" => parts}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _collection} = Metadata.fetch_collection_cached(config, collection_id)
    :ok
  end
end
