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
    %{download: download, episode: episode, mkv: mkv} = failed_download(tmp_dir)

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view |> element("#match-files-#{download.id}") |> render_click()

    view
    |> element("#match-files-form")
    |> render_submit(%{"target" => %{mkv => episode.id}})

    assert_enqueued(
      worker: Mydia.Jobs.MediaImport,
      args: %{
        "download_id" => download.id,
        "target_files" => [%{"path" => mkv, "episode_id" => episode.id}]
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
end
