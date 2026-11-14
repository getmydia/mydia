defmodule Mydia.Jobs.MediaImportPartialTest do
  @moduledoc """
  Early import: `MediaImport` with `"partial" => true` places single finished
  files of a download that is still running, and the full import at
  completion skips what was already placed.

  `async: false`: the adapter registry is a process-wide Agent, and the
  uniqueness tests start a real Oban instance.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Jobs.MediaImport
  alias Mydia.Jobs.MediaImport.Partial
  alias Mydia.Library
  alias Mydia.Repo
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

  setup %{tmp_dir: tmp_dir} do
    previous = Registry.lookup(:rqbit)
    Registry.register(:rqbit, StubAdapter)
    :persistent_term.put({StubAdapter, :removes}, [])

    on_exit(fn ->
      :persistent_term.erase({StubAdapter, :status})
      :persistent_term.erase({StubAdapter, :removes})
      if previous, do: Registry.register(:rqbit, previous)
    end)

    library_root = Path.join(tmp_dir, "library")
    File.mkdir_p!(library_root)
    {:ok, _} = Settings.create_library_path(%{path: library_root, type: :series, monitored: true})

    shared_dir = Path.join(tmp_dir, "downloads/Saltmarsh.Hollow.S01.1080p")
    File.mkdir_p!(shared_dir)

    media_item = media_item_fixture(%{type: "tv_show", title: "Saltmarsh Hollow", year: 2024})

    [ep1, ep2] =
      for n <- 1..2 do
        episode_fixture(%{
          media_item_id: media_item.id,
          season_number: 1,
          episode_number: n,
          title: "Chapter #{n}"
        })
      end

    {:ok, client} =
      Settings.create_download_client_config(%{
        name: "RqEarly",
        type: :rqbit,
        host: "localhost",
        port: 3030,
        enabled: true,
        priority: 1,
        remove_completed: true
      })

    ep1_path = Path.join(shared_dir, "Saltmarsh.Hollow.S01E01.1080p.mkv")
    ep2_path = Path.join(shared_dir, "Saltmarsh.Hollow.S01E02.1080p.mkv")
    File.write!(ep1_path, "episode one payload")
    File.write!(ep2_path, "episode two payload, longer")

    %{
      media_item: media_item,
      ep1: ep1,
      ep2: ep2,
      client: client,
      shared_dir: shared_dir,
      ep1_path: ep1_path,
      ep2_path: ep2_path
    }
  end

  defp pack_download(ctx, attrs) do
    download_fixture(
      Map.merge(
        %{
          media_item_id: ctx.media_item.id,
          status: "downloading",
          download_client: ctx.client.name,
          download_client_id: "rq-pack-1",
          title: "Saltmarsh.Hollow.S01.1080p",
          metadata: %{"season_pack" => true, "season_number" => 1, "episode_count" => 2}
        },
        attrs
      )
    )
  end

  defp stub_status(ctx, files) do
    StubAdapter.put_status(
      DownloadStatus.new(%{
        id: "rq-pack-1",
        name: "stub",
        state: :paused,
        progress: 100.0,
        download_speed: 0,
        upload_speed: 0,
        downloaded: 0,
        uploaded: 0,
        size: 0,
        eta: nil,
        ratio: 0.0,
        save_path: ctx.shared_dir,
        files: files,
        added_at: nil,
        completed_at: nil
      })
    )
  end

  defp partial_args(download, targets) do
    %{
      "download_id" => download.id,
      "target_files" => targets,
      "partial" => true,
      "use_hardlinks" => true
    }
  end

  describe "partial mode" do
    test "partial import places files, appends early_imported_paths, leaves imported_at nil and keeps the torrent",
         ctx do
      download = pack_download(ctx, %{})

      assert {:ok, :partial} =
               perform_job(
                 MediaImport,
                 partial_args(download, [%{"path" => ctx.ep1_path, "episode_id" => ctx.ep1.id}])
               )

      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.imported_at)
      assert is_nil(updated.match_status)
      assert updated.metadata["early_imported_paths"] == [ctx.ep1_path]
      assert updated.metadata["early_imported_episode_ids"] == [ctx.ep1.id]
      # Metadata recorded at grab time survives the read-modify-write.
      assert updated.metadata["episode_count"] == 2

      assert [_] = Library.list_media_files(episode_id: ctx.ep1.id)
      assert File.exists?(ctx.ep1_path), "the seeding torrent keeps its file"
      assert StubAdapter.take_removes() == []
      assert is_nil(updated.client_removed_at)

      # A second partial run appends without duplicating.
      assert {:ok, :partial} =
               perform_job(
                 MediaImport,
                 partial_args(download, [
                   %{"path" => ctx.ep1_path, "episode_id" => ctx.ep1.id},
                   %{"path" => ctx.ep2_path, "episode_id" => ctx.ep2.id}
                 ])
               )

      updated = Downloads.get_download!(download.id)
      assert updated.metadata["early_imported_paths"] == [ctx.ep1_path, ctx.ep2_path]
      assert updated.metadata["early_imported_episode_ids"] == [ctx.ep1.id, ctx.ep2.id]
      assert is_nil(updated.imported_at)
    end

    test "a failed target is left out of early_imported_paths and does not fail the others",
         ctx do
      download = pack_download(ctx, %{})
      missing = Path.join(ctx.shared_dir, "Saltmarsh.Hollow.S01E02.gone.mkv")

      assert {:ok, :partial} =
               perform_job(
                 MediaImport,
                 partial_args(download, [
                   %{"path" => missing, "episode_id" => ctx.ep2.id},
                   %{"path" => ctx.ep1_path, "episode_id" => ctx.ep1.id}
                 ])
               )

      updated = Downloads.get_download!(download.id)
      assert updated.metadata["early_imported_paths"] == [ctx.ep1_path]
      assert updated.metadata["early_imported_episode_ids"] == [ctx.ep1.id]
      assert is_nil(updated.imported_at)
      assert is_nil(updated.import_last_error)
      assert [_] = Library.list_media_files(episode_id: ctx.ep1.id)
      assert [] = Library.list_media_files(episode_id: ctx.ep2.id)
    end

    test "partial job is a no-op once the download has completed_at", ctx do
      download = pack_download(ctx, %{status: "completed", completed_at: DateTime.utc_now()})

      assert :ok =
               perform_job(
                 MediaImport,
                 partial_args(download, [%{"path" => ctx.ep1_path, "episode_id" => ctx.ep1.id}])
               )

      updated = Downloads.get_download!(download.id)
      refute Map.has_key?(updated.metadata, "early_imported_paths")
      assert [] = Library.list_media_files(episode_id: ctx.ep1.id)
    end
  end

  describe "full import after early import" do
    test "full import skips early_imported_paths and counts them for detect_partial_pack", ctx do
      download =
        pack_download(ctx, %{
          status: "completed",
          completed_at: DateTime.utc_now(),
          metadata: %{
            "season_pack" => true,
            "season_number" => 1,
            "episode_count" => 2,
            "early_imported_paths" => [ctx.ep1_path],
            "early_imported_episode_ids" => [ctx.ep1.id]
          }
        })

      stub_status(ctx, [ctx.ep1_path, ctx.ep2_path])

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir
               })

      updated = Downloads.get_download!(download.id)
      assert %DateTime{} = updated.imported_at
      # Two episodes promised, one placed early and one now: not a partial pack.
      assert is_nil(updated.match_status)
      # The early file was not placed a second time.
      assert [] = Library.list_media_files(episode_id: ctx.ep1.id)
      assert [_] = Library.list_media_files(episode_id: ctx.ep2.id)
      assert [_] = StubAdapter.take_removes()
    end

    test "full import with every file already imported early still finishes", ctx do
      download =
        pack_download(ctx, %{
          status: "completed",
          completed_at: DateTime.utc_now(),
          metadata: %{
            "season_pack" => true,
            "season_number" => 1,
            "episode_count" => 2,
            "early_imported_paths" => [ctx.ep1_path, ctx.ep2_path],
            "early_imported_episode_ids" => [ctx.ep1.id, ctx.ep2.id]
          }
        })

      sample = Path.join(ctx.shared_dir, "saltmarsh.hollow.s01.nfo")
      File.write!(sample, "release notes")
      stub_status(ctx, [ctx.ep1_path, ctx.ep2_path, sample])

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir
               })

      updated = Downloads.get_download!(download.id)
      assert %DateTime{} = updated.imported_at
      assert is_nil(updated.match_status)
      assert [] = Library.list_media_files(episode_id: ctx.ep1.id)
      assert [] = Library.list_media_files(episode_id: ctx.ep2.id)
      assert [_] = StubAdapter.take_removes()
    end

    test "full import snoozes 30s while a partial job is executing", ctx do
      download = pack_download(ctx, %{status: "completed", completed_at: DateTime.utc_now()})
      stub_status(ctx, [ctx.ep1_path, ctx.ep2_path])

      insert_executing_job(%{"download_id" => download.id, "partial" => true})
      # Neither a full job (this one, executing) nor another download's partial
      # job counts.
      insert_executing_job(%{"download_id" => download.id, "partial" => false})
      insert_executing_job(%{"download_id" => Ecto.UUID.generate(), "partial" => true})

      assert {:snooze, 30} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir,
                 "partial" => false
               })

      assert is_nil(Downloads.get_download!(download.id).imported_at)
      assert Partial.executing?(download.id)
      refute Partial.executing?(Ecto.UUID.generate())
    end
  end

  describe "exclude_early/2" do
    test "drops files whose path was imported early" do
      download = %Mydia.Downloads.Download{metadata: %{"early_imported_paths" => ["/a/one.mkv"]}}
      files = [%{path: "/a/one.mkv", name: "one.mkv"}, %{path: "/a/two.mkv", name: "two.mkv"}]

      assert [%{path: "/a/two.mkv"}] = Partial.exclude_early(files, download)
      assert files == Partial.exclude_early(files, %Mydia.Downloads.Download{metadata: nil})
    end
  end

  describe "the partial arg" do
    test "every MediaImport carries an explicit partial flag" do
      assert %{"partial" => false} = MediaImport.new(%{"download_id" => "x"}).changes.args
      assert %{partial: false} = MediaImport.new(%{download_id: "x"}).changes.args

      assert %{"partial" => true} =
               MediaImport.new(%{"download_id" => "x", "partial" => true}).changes.args
    end
  end

  # These go through a real Oban engine: with `engine: false` `Oban.insert/1`
  # raises and the callers fall back to `Repo.insert`, which skips uniqueness.
  describe "uniqueness against a real Oban engine" do
    setup do
      engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
      start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})
      :ok
    end

    test "a queued partial job does not block the full import from being enqueued", ctx do
      download = pack_download(ctx, %{})
      targets = [%{"path" => ctx.ep1_path, "episode_id" => ctx.ep1.id}]

      assert {:ok, %Oban.Job{conflict?: false}} = Partial.enqueue(download.id, targets)

      # Exactly what DownloadMonitor enqueues when the download completes.
      full =
        MediaImport.new(%{
          "download_id" => download.id,
          "save_path" => ctx.shared_dir,
          "cleanup_client" => true,
          "use_hardlinks" => true
        })

      assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(full)
      assert length(all_enqueued(worker: MediaImport)) == 2

      # A second partial job for the same download is dropped while the first
      # is queued, and so is a second full import.
      assert {:ok, %Oban.Job{conflict?: true}} = Partial.enqueue(download.id, targets)
      assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(full)
      assert length(all_enqueued(worker: MediaImport)) == 2
    end
  end

  defp insert_executing_job(args) do
    %{"download_id" => args["download_id"]}
    |> Map.merge(args)
    |> MediaImport.new()
    |> Ecto.Changeset.put_change(:state, "executing")
    |> Repo.insert!()
  end
end
