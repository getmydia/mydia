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

  test "rejecting blacklists the release and removes the download", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    %{download: download} = failed_download(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()
    view |> element("#match-files-reject") |> render_click()

    assert Mydia.Downloads.Blacklists.blacklisted?("1337x", "abc")
    refute Mydia.Repo.get(Mydia.Downloads.Download, download.id)
  end

  test "the reject button is disabled without a guid", %{conn: conn, tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "noguid")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "payload.exe"), "x")

    media_item = media_item_fixture(%{type: "tv_show"})

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        indexer: "1337x",
        import_failure_reason: "no_importable_files",
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{
          # Deliberately no "guid" — that's what this test is about. A
          # candidate snapshot is required too: the fixture's download_client
          # ("test-client") never resolves to a DownloadClientConfig, so
          # ImportCandidates.load/1 fails closed on the live listing (by
          # design — see shared_download_root?/2) and, with no snapshot to
          # fall back to, would return {:error, :unavailable} and never open
          # the modal at all, which is a different failure than the one this
          # test means to cover.
          "save_path" => dir,
          "import_candidates" => [
            %{
              "path" => Path.join(dir, "payload.exe"),
              "name" => "payload.exe",
              "size" => 1,
              "skip_reason" => "not_video_extension",
              "parsed_season" => nil,
              "parsed_episode" => nil
            }
          ]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    assert has_element?(view, "#match-files-reject[disabled]")
  end

  test "unresolved-file downloads open the same modal", %{conn: conn, tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "unresolved")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Show.S01E02.mkv"), "x")

    media_item = media_item_fixture(%{type: "tv_show"})

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        match_status: "unresolved_files",
        metadata: %{
          "save_path" => dir,
          "unresolved_files" => [
            %{"path" => Path.join(dir, "Show.S01E02.mkv"), "name" => "Show.S01E02.mkv"}
          ]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    html =
      view
      |> element("#match-files-#{download.id}")
      |> render_click()

    assert html =~ "Show.S01E02.mkv"
    assert has_element?(view, "#match-files-modal")
  end

  # The regression this task exists to prevent: every unresolved download that
  # existed before Task 4 shipped the import_candidates snapshot carries only
  # `metadata["unresolved_files"]`. The now-removed inline picker was the only
  # way to resolve those; this proves the modal's fallback keeps them
  # resolvable, not just viewable.
  test "unresolved-file downloads (no import_candidates) can be imported through the modal", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    dir = Path.join(tmp_dir, "unresolved")
    File.mkdir_p!(dir)
    file_path = Path.join(dir, "Show.S01E02.mkv")
    File.write!(file_path, "x")

    media_item = media_item_fixture(%{type: "tv_show"})

    episode =
      episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 2})

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        match_status: "unresolved_files",
        metadata: %{
          "save_path" => dir,
          "unresolved_files" => [
            %{"path" => file_path, "name" => "Show.S01E02.mkv"}
          ]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    view
    |> element("#match-files-form")
    |> render_submit(%{"target" => %{file_path => episode.id}})

    assert_enqueued(
      worker: Mydia.Jobs.MediaImport,
      args: %{
        "download_id" => download.id,
        "target_files" => [%{"path" => file_path, "episode_id" => episode.id}]
      }
    )
  end
end
