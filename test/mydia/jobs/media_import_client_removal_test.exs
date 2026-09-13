defmodule Mydia.Jobs.MediaImportClientRemovalTest do
  @moduledoc """
  Integration coverage for post-import client removal via `ClientRemoval`.

  Drives the real MediaImport job through a stub adapter so seed-aware
  deferral (qBittorrent while `:seeding`) and immediate removal (rqbit,
  paused torrents) are exercised end-to-end.

  `async: false`: the adapter registry is a process-wide Agent.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Jobs.MediaImport
  alias Mydia.Settings

  @moduletag :tmp_dir

  defmodule StubAdapter do
    @behaviour Mydia.Downloads.Client

    def put_status(status), do: :persistent_term.put({__MODULE__, :status}, status)
    def take_removes, do: :persistent_term.get({__MODULE__, :removes}, [])

    @impl true
    def get_status(_config, _client_id) do
      case :persistent_term.get({__MODULE__, :status}, nil) do
        nil -> {:error, :not_found}
        status -> {:ok, status}
      end
    end

    @impl true
    def remove_torrent(_config, id, opts) do
      list = :persistent_term.get({__MODULE__, :removes}, [])
      :persistent_term.put({__MODULE__, :removes}, [{id, opts} | list])
      :ok
    end

    @impl true
    def test_connection(_config), do: {:error, :not_implemented}
    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:error, :not_implemented}
    @impl true
    def list_torrents(_config, _opts), do: {:ok, []}
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
    @impl true
    def supported_protocols, do: [:torrent]
  end

  describe "qbittorrent with remove_completed" do
    setup do
      previous = Registry.lookup(:qbittorrent)
      Registry.register(:qbittorrent, StubAdapter)
      :persistent_term.put({StubAdapter, :removes}, [])

      on_exit(fn ->
        :persistent_term.erase({StubAdapter, :status})
        :persistent_term.erase({StubAdapter, :removes})
        if previous, do: Registry.register(:qbittorrent, previous)
      end)

      :ok
    end

    test "defers removal while seeding after import", ctx do
      %{shared_dir: shared_dir} = setup_import_dirs(ctx.tmp_dir)
      video = Path.join(shared_dir, "Silo.S01E01.Pilot.1080p.mkv")
      File.write!(video, "silo video payload")

      {media_item, episode} = tv_fixture("Silo", 2023)
      client = client_fixture("QBRemoval", :qbittorrent)

      StubAdapter.put_status(
        status(client_id: "qb-seeding-1", save_path: shared_dir, files: [video], state: :seeding)
      )

      download = download_for(media_item, episode, client, "qb-seeding-1")

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => shared_dir
               })

      updated = Downloads.get_download!(download.id)
      assert %DateTime{} = updated.imported_at
      assert is_nil(updated.client_removed_at)
      assert StubAdapter.take_removes() == []
    end

    test "removes when paused after import", ctx do
      %{shared_dir: shared_dir} = setup_import_dirs(ctx.tmp_dir)
      video = Path.join(shared_dir, "Silo.S01E01.Pilot.1080p.mkv")
      File.write!(video, "silo video payload")

      {media_item, episode} = tv_fixture("Silo", 2023)
      client = client_fixture("QBRemovalPaused", :qbittorrent)

      StubAdapter.put_status(
        status(client_id: "qb-paused-1", save_path: shared_dir, files: [video], state: :paused)
      )

      download = download_for(media_item, episode, client, "qb-paused-1")

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => shared_dir
               })

      updated = Downloads.get_download!(download.id)
      assert %DateTime{} = updated.imported_at
      assert %DateTime{} = updated.client_removed_at
      assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    end
  end

  describe "rqbit with remove_completed" do
    setup do
      previous = Registry.lookup(:rqbit)
      Registry.register(:rqbit, StubAdapter)
      :persistent_term.put({StubAdapter, :removes}, [])

      on_exit(fn ->
        :persistent_term.erase({StubAdapter, :status})
        :persistent_term.erase({StubAdapter, :removes})
        if previous, do: Registry.register(:rqbit, previous)
      end)

      :ok
    end

    test "removes immediately while seeding after import", ctx do
      %{shared_dir: shared_dir} = setup_import_dirs(ctx.tmp_dir)
      video = Path.join(shared_dir, "Silo.S01E01.Pilot.1080p.mkv")
      File.write!(video, "silo video payload")

      {media_item, episode} = tv_fixture("Silo", 2023)
      client = client_fixture("RqRemoval", :rqbit, port: 3030)

      StubAdapter.put_status(
        status(client_id: "rq-seeding-1", save_path: shared_dir, files: [video], state: :seeding)
      )

      download = download_for(media_item, episode, client, "rq-seeding-1")

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => shared_dir
               })

      updated = Downloads.get_download!(download.id)
      assert %DateTime{} = updated.imported_at
      assert %DateTime{} = updated.client_removed_at
      assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    end
  end

  ## Helpers

  defp setup_import_dirs(tmp_dir) do
    library_root = Path.join(tmp_dir, "library")
    File.mkdir_p!(library_root)
    {:ok, _} = Settings.create_library_path(%{path: library_root, type: :series, monitored: true})

    shared_dir = Path.join(tmp_dir, "downloads")
    File.mkdir_p!(shared_dir)

    %{library_root: library_root, shared_dir: shared_dir}
  end

  defp tv_fixture(title, year) do
    media_item = media_item_fixture(%{type: "tv_show", title: title, year: year})

    episode =
      episode_fixture(%{
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot"
      })

    {media_item, episode}
  end

  defp client_fixture(name, type, opts \\ []) do
    {:ok, client} =
      Settings.create_download_client_config(
        Enum.into(opts, %{
          name: name,
          type: type,
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1,
          remove_completed: true
        })
      )

    client
  end

  defp download_for(media_item, episode, client, client_id) do
    download_fixture(%{
      media_item_id: media_item.id,
      episode_id: episode.id,
      status: "completed",
      completed_at: DateTime.utc_now(),
      download_client: client.name,
      download_client_id: client_id,
      title: "Silo.S01E01.Pilot.1080p"
    })
  end

  defp status(opts) do
    DownloadStatus.new(%{
      id: Keyword.fetch!(opts, :client_id),
      name: "stub",
      state: Keyword.get(opts, :state, :completed),
      progress: 100.0,
      download_speed: 0,
      upload_speed: 0,
      downloaded: 0,
      uploaded: 0,
      size: 0,
      eta: nil,
      ratio: 0.0,
      save_path: Keyword.fetch!(opts, :save_path),
      files: Keyword.get(opts, :files),
      added_at: nil,
      completed_at: nil
    })
  end
end
