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

    # Drives the real rendered form (target[0] + hidden target_path[0]) rather
    # than handing handle_event a pre-built params map, so this exercises the
    # same encode/decode round trip a browser submission goes through.
    view
    |> form("#match-files-form", %{"target" => %{"0" => episode.id}})
    |> render_submit()

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

    # No override: the rendered select defaults to "Ignore".
    html =
      view
      |> form("#match-files-form")
      |> render_submit()

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
    # because a submission mentions it. `form/3` refuses to let an override
    # disagree with the real DOM's hidden-input value, so this simulates a
    # crafted/stale submission via the plain element, the same way a
    # WebSocket message forged outside the browser could.
    html =
      view
      |> element("#match-files-form")
      |> render_submit(%{"target" => %{"0" => episode.id}, "target_path" => %{"0" => mkv}})

    assert html =~ "Select at least one file"
    refute_enqueued(worker: Mydia.Jobs.MediaImport)
  end

  test "refuses a submitted path flagged missing", %{conn: conn, tmp_dir: tmp_dir} do
    %{download: download, episode: episode} =
      failed_download_with_missing_candidate(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    # The candidate's <select> is disabled in the DOM (missing files can't be
    # targeted normally), so a real form submit could never carry target[0].
    # Force it via the plain element to prove the server refuses it too.
    html =
      view
      |> element("#match-files-form")
      |> render_submit(%{"target" => %{"0" => episode.id}})

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
    %{download: download} = download_without_episodes(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    # A crafted or stale submission: nothing in the DOM offers this value for
    # a tv_show (previous test), but the server must refuse it independently.
    # Rejected outright (not silently dropped down to "nothing selected"):
    # an invalid target now fails the whole submission with a specific
    # error, per the same re-validation that guards a stale episode_id.
    html =
      view
      |> element("#match-files-form")
      |> render_submit(%{"target" => %{"0" => "movie"}})

    assert html =~ "no longer valid for this download"
    refute_enqueued(worker: Mydia.Jobs.MediaImport)
  end

  test "refuses a submitted episode that belongs to a different show than the download is now bound to",
       %{conn: conn, tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(dir)
    video = Path.join(dir, "Show.S01E01.mkv")
    File.write!(video, "y")

    show_a = media_item_fixture(%{type: "tv_show"})

    episode_a =
      episode_fixture(%{media_item_id: show_a.id, season_number: 1, episode_number: 1})

    show_b = media_item_fixture(%{type: "tv_show"})
    episode_fixture(%{media_item_id: show_b.id, season_number: 1, episode_number: 1})

    download =
      download_fixture(%{
        media_item_id: show_a.id,
        indexer: "1337x",
        import_failure_reason: "no_importable_files",
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{
          "guid" => "abc",
          "save_path" => dir,
          "import_candidates" => [
            %{
              "path" => video,
              "name" => "Show.S01E01.mkv",
              "size" => 100,
              "skip_reason" => nil,
              "parsed_season" => 1,
              "parsed_episode" => 1
            }
          ]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    # Opened while the download is bound to show A — the (now-stale)
    # in-memory modal assign offers show A's episode as a target.
    view |> element("#match-files-#{download.id}") |> render_click()

    # The download gets re-bound to a DIFFERENT show while the modal stays
    # open, exactly what the separate match/re-match modal does — this modal
    # has no way to notice.
    {:ok, _} = Mydia.Downloads.manually_match_download(Mydia.Repo.reload!(download), show_b.id)

    # Submit episode_a's id, the value the stale modal offered. The server
    # must re-check against the CURRENT media_item (show B), not the assign
    # captured at open time, and refuse it — otherwise the file lands under
    # show B's destination path while linked to show A's episode.
    html =
      view
      |> element("#match-files-form")
      |> render_submit(%{"target" => %{"0" => episode_a.id}})

    assert html =~ "no longer valid for this download"

    refute_enqueued(
      worker: Mydia.Jobs.MediaImport,
      args: %{"target_files" => [%{"path" => video, "episode_id" => episode_a.id}]}
    )
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

  test "rejecting without a guid still removes the download but does not blacklist", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
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
    refute has_element?(view, "#match-files-reject[disabled]")

    view |> element("#match-files-reject") |> render_click()

    refute Mydia.Downloads.Blacklists.blacklisted?("1337x", "missing-guid")
    refute Mydia.Repo.get(Mydia.Downloads.Download, download.id)
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
  # A path shaped like the anime release that motivated this feature: bracket
  # groups back to back, the exact form Plug's decode_pair mis-splits on
  # "][". A form field literally named `target[<this path>]` (the pre-fix
  # wiring) decodes into nested garbage and the file is silently dropped —
  # confirmed by running this fixture through `form/3` with a path-keyed
  # target map against the pre-fix template: `assert_enqueued` failed with
  # "Instead found: []", the same "Select at least one file" dead end the
  # operator hit in production.
  defp failed_download_with_bracket_path(tmp_dir) do
    dir = Path.join(tmp_dir, "[BlackRabbit] Show (2021) [Bluray-1080p][Opus 2.0]")
    File.mkdir_p!(dir)
    video = Path.join(dir, "ep01.mkv")
    File.write!(video, "y")

    media_item = media_item_fixture(%{type: "tv_show"})

    episode =
      episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        indexer: "1337x",
        import_failure_reason: "no_importable_files",
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{
          "guid" => "abc",
          "save_path" => dir,
          "import_candidates" => [
            %{
              "path" => video,
              "name" => "ep01.mkv",
              "size" => 1024,
              "skip_reason" => nil,
              "parsed_season" => 1,
              "parsed_episode" => 1
            }
          ]
        }
      })

    %{download: download, episode: episode, video: video}
  end

  test "imports a file whose path contains nested brackets", %{conn: conn, tmp_dir: tmp_dir} do
    %{download: download, episode: episode, video: video} =
      failed_download_with_bracket_path(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    # Drives the real rendered form rather than handing handle_event a
    # pre-built params map: `form/3` reads the actual `target[0]` /
    # `target_path[0]` field names and values out of the DOM, and
    # `render_submit/1` round-trips them through the same
    # `Plug.Conn.Query.encode/1` + `Plug.Conn.Query.decode/1` a real browser
    # submission goes through. That round trip is exactly what mangled the
    # old path-keyed field name (see the fixture comment above).
    view
    |> form("#match-files-form", %{"target" => %{"0" => episode.id}})
    |> render_submit()

    assert_enqueued(
      worker: Mydia.Jobs.MediaImport,
      args: %{
        "download_id" => download.id,
        "target_files" => [%{"path" => video, "episode_id" => episode.id}]
      }
    )
  end

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
    |> form("#match-files-form", %{"target" => %{"0" => episode.id}})
    |> render_submit()

    assert_enqueued(
      worker: Mydia.Jobs.MediaImport,
      args: %{
        "download_id" => download.id,
        "target_files" => [%{"path" => file_path, "episode_id" => episode.id}]
      }
    )
  end
end
