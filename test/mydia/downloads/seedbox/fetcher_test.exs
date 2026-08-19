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

  test "transfers a multi-file directory preserving its structure", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    release_dir = Path.join(remote_root, "Show.S01")
    File.mkdir_p!(Path.join(release_dir, "Season 01"))
    File.write!(Path.join(release_dir, "Season 01/e01.mkv"), "episode one")
    File.write!(Path.join(release_dir, "Season 01/e02.mkv"), "episode two")
    File.write!(Path.join(release_dir, "readme.nfo"), "nfo contents")

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port),
               remote_path: release_dir,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    save_path = reloaded.metadata["save_path"]

    assert File.read!(Path.join(save_path, "Season 01/e01.mkv")) == "episode one"
    assert File.read!(Path.join(save_path, "Season 01/e02.mkv")) == "episode two"
    assert File.read!(Path.join(save_path, "readme.nfo")) == "nfo contents"
  end

  test "a directory transfer skips a file that's already complete on disk, without redownloading it",
       %{
         remote_root: remote_root,
         local_root: local_root,
         port: port
       } do
    download = insert_download!("seedbox-qbit")
    release_dir = Path.join(remote_root, "Show.S01")
    File.mkdir_p!(Path.join(release_dir, "Season 01"))
    File.write!(Path.join(release_dir, "Season 01/e01.mkv"), "episode one")
    File.write!(Path.join(release_dir, "Season 01/e02.mkv"), "episode two")

    # Pre-place file 1 exactly as a prior, successful attempt would have left
    # it (correct final path, correct size) — simulating a retry after file 2
    # failed on an earlier pass. Its mtime is forced well into the past so
    # that, unlike byte-identical content, an unwanted rewrite is detectable:
    # a genuine skip leaves the mtime untouched, a redownload (even one that
    # writes identical bytes) would bump it.
    local_dir = Path.join(local_root, download.id)
    File.mkdir_p!(Path.join(local_dir, "Season 01"))
    existing_path = Path.join(local_dir, "Season 01/e01.mkv")
    File.write!(existing_path, "episode one")
    File.touch!(existing_path, System.os_time(:second) - 3600)
    %{mtime: mtime_before} = File.stat!(existing_path)

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port),
               remote_path: release_dir,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    save_path = reloaded.metadata["save_path"]
    assert File.read!(Path.join(save_path, "Season 01/e02.mkv")) == "episode two"

    %{mtime: mtime_after} = File.stat!(existing_path)
    assert mtime_after == mtime_before
  end

  test "delete_after_transfer removes the remote copy only after a verified transfer", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    remote_file = Path.join(remote_root, "release.mkv")
    File.write!(remote_file, "delete me after this pulls down cleanly")

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port, %{"delete_after_transfer" => true}),
               remote_path: remote_file,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    assert reloaded.metadata["save_path"]
    refute File.exists?(remote_file)
  end

  test "a failed remote delete after a successful transfer does not fail the download", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    locked_dir = Path.join(remote_root, "locked")
    File.mkdir_p!(locked_dir)
    remote_file = Path.join(locked_dir, "release.mkv")
    File.write!(remote_file, "read-only parent blocks delete")

    # Opening a named file for read only needs execute ("search") on its
    # containing directory, but `:ssh_sftp.delete/2` unlinks the file,
    # which needs write on that same directory (POSIX unlink semantics).
    # `0o555` (r-x) keeps the transfer working while making the
    # post-transfer delete fail with a real, non-mocked permission error.
    File.chmod!(locked_dir, 0o555)

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port, %{"delete_after_transfer" => true}),
               remote_path: remote_file,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    # Restore write access so `on_exit`'s `File.rm_rf!(remote_root)` can
    # clean up `locked_dir`'s contents without erroring.
    File.chmod!(locked_dir, 0o755)

    reloaded = Repo.get!(Download, download.id)
    save_path = reloaded.metadata["save_path"]
    assert save_path
    refute reloaded.import_failed_at
    assert File.read!(Path.join(save_path, "release.mkv")) == "read-only parent blocks delete"
    assert File.exists?(remote_file)
  end

  test "delete_after_transfer removes a remote directory recursively", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    release_dir = Path.join(remote_root, "Show.S01")
    File.mkdir_p!(Path.join(release_dir, "Season 01"))
    File.write!(Path.join(release_dir, "Season 01/e01.mkv"), "episode one")

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port, %{"delete_after_transfer" => true}),
               remote_path: release_dir,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    assert reloaded.metadata["save_path"]
    refute File.exists?(release_dir)
  end

  test "delete_after_transfer as the string \"false\" does not delete the remote copy (regression)",
       %{
         remote_root: remote_root,
         local_root: local_root,
         port: port
       } do
    # `connection_settings` is a `Mydia.Settings.JsonMapType` column with zero
    # per-key coercion; the checkbox markup for `delete_after_transfer`
    # currently omits an unchecked box from form params entirely, but a
    # future switch to `<.input type="checkbox">` (the project's documented
    # convention) would submit the STRING "false" for an unchecked box. Only
    # `nil`/`false` are falsy in Elixir, so a naive `if Map.get(...) do`
    # check would treat "false" as truthy and delete the remote file after
    # every verified transfer. This must not happen.
    download = insert_download!("seedbox-qbit")
    remote_file = Path.join(remote_root, "release.mkv")
    File.write!(remote_file, "stays put even when delete_after_transfer is the string false")

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port, %{"delete_after_transfer" => "false"}),
               remote_path: remote_file,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    reloaded = Repo.get!(Download, download.id)
    assert reloaded.metadata["save_path"]
    assert File.exists?(remote_file)
  end

  test "delete_after_transfer defaults to false, leaving the remote copy in place", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    remote_file = Path.join(remote_root, "release.mkv")
    File.write!(remote_file, "stays put")

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port),
               remote_path: remote_file,
               download_directory: local_root
             )

    wait_for_fetcher_exit(download.id)

    assert File.exists?(remote_file)
  end

  # Issue #281. finalize/1 runs after transfer_all/2 has copied everything and
  # maybe_delete_remote/2 has removed the source, so a missing row must be
  # terminal: retrying would re-open SFTP for a remote path that no longer
  # exists, three times over.
  test "a download deleted mid-fetch stops the fetcher instead of retrying", %{
    remote_root: remote_root,
    local_root: local_root,
    port: port
  } do
    download = insert_download!("seedbox-qbit")
    remote_file = Path.join(remote_root, "release.mkv")
    File.write!(remote_file, "hello world")

    Repo.delete!(download)

    assert :ok =
             Fetcher.claim(
               download_id: download.id,
               client_name: "seedbox-qbit",
               remote_fetch: remote_fetch_config(port),
               remote_path: remote_file,
               download_directory: local_root
             )

    # 20 attempts × 100ms = a 2s budget, against a 5s first retry delay. Exiting
    # inside this window is the proof that the missing row was terminal.
    wait_for_fetcher_exit(download.id, 20)
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
