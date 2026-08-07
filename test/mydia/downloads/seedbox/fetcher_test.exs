defmodule Mydia.Downloads.Seedbox.FetcherTest do
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Seedbox.Fetcher
  alias Mydia.Repo
  alias Mydia.SftpFixture

  setup do
    ensure_started!({Registry, keys: :unique, name: Mydia.Downloads.Seedbox.FetcherRegistry})

    ensure_started!(
      {DynamicSupervisor, name: Mydia.Downloads.Seedbox.FetcherSupervisor, strategy: :one_for_one}
    )

    remote_root =
      Path.join(System.tmp_dir!(), "seedbox_remote_#{System.unique_integer([:positive])}")

    File.mkdir_p!(remote_root)
    on_exit(fn -> File.rm_rf!(remote_root) end)

    local_root =
      Path.join(System.tmp_dir!(), "seedbox_local_#{System.unique_integer([:positive])}")

    File.mkdir_p!(local_root)
    on_exit(fn -> File.rm_rf!(local_root) end)

    {daemon_ref, port} = SftpFixture.start(remote_root, "seeduser", "seedpass")
    on_exit(fn -> :ssh.stop_daemon(daemon_ref) end)

    %{remote_root: remote_root, local_root: local_root, port: port}
  end

  defp ensure_started!(spec) do
    case start_supervised(spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp insert_download!(client_name) do
    %Download{}
    |> Download.changeset(%{
      title: "Test Release",
      download_client: client_name,
      download_client_id: "torrent-#{System.unique_integer([:positive])}",
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp remote_fetch_config(port, overrides \\ %{}) do
    Map.merge(
      %{
        "enabled" => true,
        "host" => "127.0.0.1",
        "port" => port,
        "username" => "seeduser",
        "auth_method" => "password",
        "password" => "seedpass"
      },
      overrides
    )
  end

  test "transfers a single remote file to local storage and records save_path", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    payload = :crypto.strong_rand_bytes(500_000)
    remote_file = Path.join(remote_root, "release.mkv")
    File.write!(remote_file, payload)

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port),
               remote_path: remote_file,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    assert reloaded.bytes_pulled == byte_size(payload)
    refute reloaded.completed_at

    save_path = reloaded.metadata["save_path"]
    assert save_path == Path.join(local_root, download.id)
    assert File.read!(Path.join(save_path, "release.mkv")) == payload
  end

  test "concurrent claims for the same download collapse into one fetcher", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    File.write!(Path.join(remote_root, "release.mkv"), "hello world")

    opts = [
      download_id: download.id,
      client_name: "seedbox-qbit",
      remote_fetch: remote_fetch_config(port),
      remote_path: Path.join(remote_root, "release.mkv"),
      download_directory: local_root
    ]

    assert :ok = Fetcher.claim(opts)
    assert :ok = Fetcher.claim(opts)

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    assert reloaded.metadata["save_path"]
  end

  test "a missing remote file retries then marks the download failed", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port),
               remote_path: Path.join(remote_root, "does-not-exist.mkv"),
               download_directory: local_root,
               max_retries: 1,
               retry_delay_base_ms: 10
             )

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    assert reloaded.import_failed_at
    assert reloaded.import_last_error =~ "seedbox_fetch_failed"
  end

  test "resumes a partial .part file from its on-disk size", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    payload = String.duplicate("x", 1000) <> String.duplicate("y", 1000)
    remote_file = Path.join(remote_root, "release.mkv")
    File.write!(remote_file, payload)

    local_dir = Path.join(local_root, download.id)
    File.mkdir_p!(local_dir)
    File.write!(Path.join(local_dir, "release.mkv.part"), String.duplicate("x", 1000))

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port),
               remote_path: remote_file,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    save_path = reloaded.metadata["save_path"]
    assert File.read!(Path.join(save_path, "release.mkv")) == payload
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
