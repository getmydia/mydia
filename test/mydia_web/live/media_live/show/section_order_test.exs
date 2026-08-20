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

  setup %{conn: conn} do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # recommendations load can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "a movie renders its own files above the recommendations rail", %{conn: conn} do
    source_tmdb_id = System.unique_integer([:positive])

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
        "id" => System.unique_integer([:positive]),
        "title" => "The Eternal Daughter",
        "release_date" => "2022-12-02",
        "poster_path" => "/p.jpg"
      }
    ])

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
end
