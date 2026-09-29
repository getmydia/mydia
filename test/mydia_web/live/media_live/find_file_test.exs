defmodule MydiaWeb.MediaLive.FindFileTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Library.{ImportCandidate, MediaFile}
  alias Mydia.Repo

  @moduletag :tmp_dir

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  defp on_disk(root, rel) do
    abs = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "data")
    rel
  end

  test "a movie with no file finds and attaches a parked file", %{conn: conn, tmp_dir: tmp} do
    lp = library_path_fixture(%{type: "movies", path: tmp})

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Zephyr Station",
        year: 2030,
        tmdb_id: 900_401,
        metadata_source: :tmdb
      })

    warm_recommendations_cache(900_401, :movie, [])
    warm_movie_details_cache(900_401)

    rel = on_disk(tmp, "misc/zs.mkv")

    candidate =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: rel,
        provider_type: "tmdb",
        provider_id: "900401",
        dismissed_at: ~U[2026-09-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    view |> element("#find-file-button") |> render_click()
    assert has_element?(view, "#find-file-modal")
    assert has_element?(view, "#find-file-candidate-#{candidate.id}")

    view |> element("#find-file-attach-#{candidate.id}") |> render_click()

    refute has_element?(view, "#find-file-modal")
    assert Repo.get_by(MediaFile, media_item_id: movie.id, relative_path: rel)
    refute Repo.get(ImportCandidate, candidate.id)
  end

  test "the search box narrows to a path", %{conn: conn, tmp_dir: tmp} do
    lp = library_path_fixture(%{type: "movies", path: tmp})
    movie = media_item_fixture(%{type: "movie", title: "Zephyr Station", year: 2030})

    other =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: on_disk(tmp, "Quillmere/q.mkv")
      )

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    view |> element("#find-file-button") |> render_click()
    refute has_element?(view, "#find-file-candidate-#{other.id}")

    view |> form("#find-file-search", %{"query" => "quill"}) |> render_change()
    assert has_element?(view, "#find-file-candidate-#{other.id}")
  end

  test "an episode row with no file offers find file", %{conn: conn, tmp_dir: tmp} do
    lp = library_path_fixture(%{type: "series", path: tmp})
    show = media_item_fixture(%{type: "tv_show", title: "Lantern Coast", tvdb_id: 900_402})
    episode = episode_fixture(media_item_id: show.id, season_number: 1, episode_number: 4)
    rel = on_disk(tmp, "Lantern Coast/Lantern.Coast.S01E04.mkv")

    candidate =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: rel,
        parsed_info: %{"season" => 1, "episodes" => [4]}
      )

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    # The season opens by default (it holds the next episode to watch).
    render_click(view, "toggle_episode_expanded", %{"episode-id" => episode.id})

    view |> element("#find-file-episode-#{episode.id}") |> render_click()
    view |> element("#find-file-attach-#{candidate.id}") |> render_click()

    assert Repo.get_by(MediaFile, episode_id: episode.id, relative_path: rel)
  end

  test "a movie that has a file shows no find file button", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie"})
    media_file_fixture(media_item_id: movie.id)

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    refute has_element?(view, "#find-file-button")
  end

  test "scan starts a review run", %{conn: conn, tmp_dir: tmp} do
    library_path_fixture(%{type: "movies", path: tmp})
    movie = media_item_fixture(%{type: "movie"})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    view |> element("#find-file-button") |> render_click()
    view |> element("#find-file-scan") |> render_click()

    assert [%{mode: :review}] = Repo.all(Mydia.Library.ImportRun)
    assert has_element?(view, "#find-file-scanning")
  end

  # A run that finishes before the view subscribes would never broadcast to
  # it. Forcing that race is not deterministic, so this pins the settle path
  # the post-subscribe re-read shares with the broadcast handler.
  test "a finished run clears the scanning indicator", %{conn: conn, tmp_dir: tmp} do
    library_path_fixture(%{type: "movies", path: tmp})
    movie = media_item_fixture(%{type: "movie"})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    view |> element("#find-file-button") |> render_click()
    view |> element("#find-file-scan") |> render_click()
    assert has_element?(view, "#find-file-scanning")

    [run] = Repo.all(Mydia.Library.ImportRun)
    send(view.pid, {:import_run_progress, %{run | status: :done}})
    render(view)

    refute has_element?(view, "#find-file-scanning")
  end

  test "a repeated scan click keeps a single scanning entry", %{conn: conn, tmp_dir: tmp} do
    library_path_fixture(%{type: "movies", path: tmp})
    movie = media_item_fixture(%{type: "movie"})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    view |> element("#find-file-button") |> render_click()
    view |> element("#find-file-scan") |> render_click()
    view |> element("#find-file-scan") |> render_click()

    [run] = Repo.all(Mydia.Library.ImportRun)
    send(view.pid, {:import_run_progress, %{run | status: :done}})
    render(view)

    refute has_element?(view, "#find-file-scanning")
  end

  test "an episode of another show does not open the dialog", %{conn: conn} do
    show = media_item_fixture(%{type: "tv_show", title: "Lantern Coast"})
    other = media_item_fixture(%{type: "tv_show", title: "Quillmere Bay"})
    episode = episode_fixture(media_item_id: other.id, season_number: 1, episode_number: 1)

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    html = render_click(view, "open_find_file", %{"episode-id" => episode.id})

    refute has_element?(view, "#find-file-modal")
    assert html =~ "not on this page"
  end

  test "a malformed episode id flashes instead of crashing", %{conn: conn} do
    show = media_item_fixture(%{type: "tv_show", title: "Lantern Coast"})

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    html = render_click(view, "open_find_file", %{"episode-id" => "not-a-uuid"})

    refute has_element?(view, "#find-file-modal")
    assert html =~ "not on this page"
  end
end
