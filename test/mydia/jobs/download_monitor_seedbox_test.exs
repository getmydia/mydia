defmodule Mydia.Jobs.DownloadMonitorSeedboxTest do
  @moduledoc """
  End-to-end proof that the seedbox remote-fetch pieces (Tasks 1-4) compose
  correctly behind `DownloadMonitor.perform/1`: a fake qBittorrent WebUI
  (Bypass) reports a torrent as finished seeding, `Seedbox.maybe_apply_remote_fetch/3`
  (wired into `History.fetch_all_client_statuses/2`) claims a real `Fetcher`,
  the `Fetcher` pulls a real file over SFTP from a real local `:ssh` daemon,
  and a second monitor pass completes the download and enqueues a real
  `MediaImport` job pointing at the LOCAL path.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Seedbox.Fetcher
  alias Mydia.Jobs.DownloadMonitor
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.SftpFixture

  setup do
    ensure_started!({Registry, keys: :unique, name: Mydia.Downloads.Seedbox.FetcherRegistry})

    ensure_started!(
      {DynamicSupervisor, name: Mydia.Downloads.Seedbox.FetcherSupervisor, strategy: :one_for_one}
    )

    # The app skips Oban in test (config/test.exs sets `engine: false`), so a
    # bare `Oban.insert/1` inside `DownloadMonitor.handle_completion/1` (which,
    # unlike the stuck-download retry path, has no `rescue RuntimeError ->
    # Repo.insert(...)` fallback) cannot resolve a config and raises. Start an
    # isolated, manual-mode instance under the default `Oban` name so the real
    # (unrescued) enqueue call succeeds and lands a row `assert_enqueued` can
    # see — same pattern as SegmentDetectionTest / PathMappingIssueTest.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite

    start_supervised!(
      {Oban, repo: Mydia.Repo, engine: engine, testing: :manual, queues: false, plugins: false}
    )

    bypass = Bypass.open()

    remote_root =
      Path.join(System.tmp_dir!(), "seedbox_dm_remote_#{System.unique_integer([:positive])}")

    File.mkdir_p!(remote_root)
    on_exit(fn -> File.rm_rf!(remote_root) end)

    local_root =
      Path.join(System.tmp_dir!(), "seedbox_dm_local_#{System.unique_integer([:positive])}")

    File.mkdir_p!(local_root)
    on_exit(fn -> File.rm_rf!(local_root) end)

    {daemon_ref, sftp_port} = SftpFixture.start(remote_root, "seeduser", "seedpass")
    on_exit(fn -> :ssh.stop_daemon(daemon_ref) end)

    %{bypass: bypass, remote_root: remote_root, local_root: local_root, sftp_port: sftp_port}
  end

  defp ensure_started!(spec) do
    case start_supervised(spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "a torrent that finishes seeding on the seedbox gets pulled locally and enqueues MediaImport",
       %{bypass: bypass, remote_root: remote_root, local_root: local_root, sftp_port: sftp_port} do
    payload = "fake release contents"
    File.write!(Path.join(remote_root, "release.mkv"), payload)

    {:ok, client} =
      Settings.create_download_client_config(%{
        name: "seedbox-qbit-dm",
        type: :qbittorrent,
        host: "localhost",
        port: bypass.port,
        username: "admin",
        password: "adminpass",
        download_directory: local_root,
        connection_settings: %{
          "remote_fetch" => %{
            "enabled" => true,
            "host" => "127.0.0.1",
            "port" => sftp_port,
            "username" => "seeduser",
            "auth_method" => "password",
            "password" => "seedpass"
          }
        }
      })

    Bypass.stub(bypass, "POST", "/api/v2/auth/login", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "SID=test-sid; HttpOnly")
      |> Plug.Conn.resp(200, "Ok.")
    end)

    Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([
          %{
            "hash" => "torrent-1",
            "name" => "Release",
            "state" => "stalledUP",
            "progress" => 1.0,
            "size" => byte_size(payload),
            "save_path" => Path.join(remote_root, "release.mkv"),
            "dlspeed" => 0,
            "upspeed" => 0,
            "downloaded" => byte_size(payload),
            "uploaded" => 0,
            "eta" => 0,
            "ratio" => 1.0,
            "content_path" => Path.join(remote_root, "release.mkv"),
            "added_on" => 0,
            "completion_on" => 0
          }
        ])
      )
    end)

    download =
      %Download{}
      |> Download.changeset(%{
        title: "Release",
        download_client: client.name,
        download_client_id: "torrent-1",
        metadata: %{}
      })
      |> Repo.insert!()

    # First tick: sees the remote torrent finished seeding, claims a Fetcher,
    # and — since the local pull hasn't happened yet — must NOT enqueue
    # MediaImport this tick.
    #
    # The claim's derived :queued status for *this* poll is decided from the
    # download snapshot read at the top of `list_downloads_with_status/1`,
    # taken before the Fetcher is claimed — so it is deterministic regardless
    # of transfer speed. Whether the real Fetcher genserver is *still*
    # registered by the time we check here is not: a tiny payload over an
    # already-warm loopback SSH connection (e.g. after sibling seedbox tests
    # have run in the same suite) can finish before this assertion runs. Both
    # outcomes prove the same thing — the Fetcher genuinely ran — so accept
    # either rather than asserting a fragile mid-flight snapshot.
    assert :ok = perform_job(DownloadMonitor, %{})

    case Fetcher.whereis(download.id) do
      {:ok, _pid} ->
        :ok

      :error ->
        assert Repo.get!(Download, download.id).metadata["save_path"],
               "Fetcher is neither running nor finished — it was never claimed"
    end

    refute_enqueued(worker: Mydia.Jobs.MediaImport)

    wait_for_fetcher_exit(download.id)

    # Second tick: the Fetcher has written metadata["save_path"], so the real
    # "seeding" status now flows through unmodified and DownloadMonitor
    # completes the download and enqueues MediaImport with the LOCAL path.
    assert :ok = perform_job(DownloadMonitor, %{})

    reloaded = Repo.get!(Download, download.id)
    assert reloaded.completed_at
    assert reloaded.metadata["save_path"] == Path.join(local_root, download.id)
    assert File.read!(Path.join(reloaded.metadata["save_path"], "release.mkv")) == payload

    assert_enqueued(
      worker: Mydia.Jobs.MediaImport,
      args: %{"download_id" => download.id, "save_path" => reloaded.metadata["save_path"]}
    )
  end

  defp wait_for_fetcher_exit(download_id, attempts \\ 100)
  defp wait_for_fetcher_exit(_download_id, 0), do: flunk("fetcher did not exit in time")

  defp wait_for_fetcher_exit(download_id, attempts) do
    case Fetcher.whereis(download_id) do
      :error ->
        :ok

      {:ok, _pid} ->
        Process.sleep(100)
        wait_for_fetcher_exit(download_id, attempts - 1)
    end
  end
end
