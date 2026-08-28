defmodule MydiaWeb.MediaLive.Show.SectionOrderTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only shared
  # with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers
  import Mydia.MetadataCacheHelpers

  # Every section whose position this page decides. Each case asserts the whole
  # list rather than a pairwise precedence, so a section that stops rendering
  # fails the test instead of passing quietly.
  #
  # timeline-section is no longer a member of the main column: it is a sibling
  # aside placed after it, so it always sorts last in document order.
  @sections "#seasons-episodes-section, #media-files-section, " <>
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
             "recommendations-rail",
             "timeline-section"
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

    # No media-files-section: a show's files hang off its episodes, so
    # media_item.media_files is always empty here and the card guards itself
    # out.
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
             "franchise-section",
             "recommendations-rail",
             "timeline-section"
           ]
  end

  # History is no longer part of the main column's ordering decision: it is a
  # sibling aside, third grid column at xl and a full-width row below it. It
  # therefore always sorts last in document order regardless of what the main
  # column contains. Pinned here so a later edit that folds it back into the
  # flow fails loudly.
  test "a movie with no media files renders its history outside the main column", %{conn: conn} do
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

    # No media-files-section: it guards on a non-empty media_files. No
    # franchise-section: the fixture carries no collection_id.
    assert section_ids(view) == [
             "recommendations-rail",
             "timeline-section"
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
end
