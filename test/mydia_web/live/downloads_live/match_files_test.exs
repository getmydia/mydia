defmodule MydiaWeb.DownloadsLive.MatchFilesTest do
  # Not async: a connected LiveView mount runs in a separate process from the
  # test. Under PostgreSQL with async: true the sandbox is non-shared, so that
  # process cannot see the rows this test inserts.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  @moduletag :tmp_dir

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp failed_download(tmp_dir) do
    dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(dir)
    exe = Path.join(dir, "payload.exe")
    mkv = Path.join(dir, "Show.S01E01.mkv")
    File.write!(exe, "x")
    File.write!(mkv, "y")

    media_item = media_item_fixture(%{type: "tv_show"})

    episode =
      episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        indexer: "1337x",
        import_failure_reason: "no_importable_files",
        import_last_error: "No importable files found for TV show.",
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{
          "guid" => "abc",
          "save_path" => dir,
          "import_candidates" => [
            %{
              "path" => exe,
              "name" => "payload.exe",
              "size" => 891_885_056,
              "skip_reason" => "not_video_extension",
              "parsed_season" => nil,
              "parsed_episode" => nil,
              "probe" => %{"status" => "not_media", "detail" => "invalid data"}
            }
          ]
        }
      })

    %{download: download, episode: episode, exe: exe, mkv: mkv}
  end

  # A candidate recorded at failure time whose file has since vanished from
  # disk — `ImportCandidates.load/1` marks it `"missing" => true`.
  defp failed_download_with_missing_candidate(tmp_dir) do
    dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(dir)
    ghost = Path.join(dir, "ghost.mkv")

    media_item = media_item_fixture(%{type: "tv_show"})

    episode =
      episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        indexer: "1337x",
        import_failure_reason: "no_importable_files",
        import_last_error: "No importable files found for TV show.",
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{
          "guid" => "abc",
          "save_path" => dir,
          "import_candidates" => [
            %{
              "path" => ghost,
              "name" => "ghost.mkv",
              "size" => 100,
              "skip_reason" => nil,
              "parsed_season" => 1,
              "parsed_episode" => 1
            }
          ]
        }
      })

    %{download: download, episode: episode, ghost: ghost}
  end

  # A tv_show whose episodes have never been fetched (an ordinary, common
  # state, not an error) — `list_episodes/1` returns `[]` for it, same as it
  # would for an actual movie's media item. The modal must tell these two
  # cases apart from `download.media_item.type`, not from the empty list.
  defp download_without_episodes(tmp_dir) do
    dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(dir)
    exe = Path.join(dir, "payload.exe")
    File.write!(exe, "x")

    media_item = media_item_fixture(%{type: "tv_show"})

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        indexer: "1337x",
        import_failure_reason: "no_importable_files",
        import_last_error: "No importable files found for TV show.",
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{
          "guid" => "abc",
          "save_path" => dir,
          "import_candidates" => [
            %{
              "path" => exe,
              "name" => "payload.exe",
              "size" => 891_885_056,
              "skip_reason" => "not_video_extension",
              "parsed_season" => nil,
              "parsed_episode" => nil,
              "probe" => %{"status" => "not_media", "detail" => "invalid data"}
            }
          ]
        }
      })

    %{download: download, exe: exe}
  end

  test "opens the modal and lists the download's files", %{conn: conn, tmp_dir: tmp_dir} do
    %{download: download} = failed_download(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    html =
      view
      |> element("#match-files-#{download.id}")
      |> render_click()

    assert html =~ "payload.exe"
    assert has_element?(view, "#match-files-modal")
  end

  test "imports only the selected file", %{conn: conn, tmp_dir: tmp_dir} do
    %{download: download, episode: episode, exe: exe} = failed_download(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    view
    |> element("#match-files-form")
    |> render_submit(%{"target" => %{exe => episode.id}})

    assert_enqueued(
      worker: Mydia.Jobs.MediaImport,
      args: %{
        "download_id" => download.id,
        "target_files" => [%{"path" => exe, "episode_id" => episode.id}]
      }
    )
  end

  test "refuses to submit with nothing selected", %{conn: conn, tmp_dir: tmp_dir} do
    %{download: download} = failed_download(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    html =
      view
      |> element("#match-files-form")
      |> render_submit(%{"target" => %{}})

    assert html =~ "Select at least one file"
    refute_enqueued(worker: Mydia.Jobs.MediaImport)
  end

  test "refuses a submitted path that is not among the candidates", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    %{download: download, episode: episode, mkv: mkv} = failed_download(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    # `mkv` sits on disk in the same folder, but was never part of the
    # recorded/live candidate list — nothing server-side may trust it just
    # because a submission mentions it.
    html =
      view
      |> element("#match-files-form")
      |> render_submit(%{"target" => %{mkv => episode.id}})

    assert html =~ "Select at least one file"
    refute_enqueued(worker: Mydia.Jobs.MediaImport)
  end

  test "refuses a submitted path flagged missing", %{conn: conn, tmp_dir: tmp_dir} do
    %{download: download, episode: episode, ghost: ghost} =
      failed_download_with_missing_candidate(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    html =
      view
      |> element("#match-files-form")
      |> render_submit(%{"target" => %{ghost => episode.id}})

    assert html =~ "Select at least one file"
    refute_enqueued(worker: Mydia.Jobs.MediaImport)
  end

  test "does not render the movie option for a tv_show with no episodes loaded", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    %{download: download} = download_without_episodes(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    html =
      view
      |> element("#match-files-#{download.id}")
      |> render_click()

    refute html =~ "Import as this movie"
    assert has_element?(view, "#match-files-blocked")
    assert has_element?(view, "#match-files-import[disabled]")
  end

  test "refuses a submission that targets the movie destination against a tv_show", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    %{download: download, exe: exe} = download_without_episodes(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    # A crafted or stale submission: nothing in the DOM offers this value for
    # a tv_show (previous test), but the server must refuse it independently.
    html =
      view
      |> element("#match-files-form")
      |> render_submit(%{"target" => %{exe => "movie"}})

    assert html =~ "Select at least one file"
    refute_enqueued(worker: Mydia.Jobs.MediaImport)
  end
end
