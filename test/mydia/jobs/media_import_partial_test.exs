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
  alias Mydia.Jobs.MediaImport.{Args, Partial}
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
      # Re-placing ep1 reused its record rather than adding a second one.
      assert [_] = Library.list_media_files(episode_id: ctx.ep1.id)
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
      # Recorded so the monitor stops offering it; the full import still tries.
      assert updated.metadata["early_import_failed_paths"] == [missing]
      assert is_nil(updated.imported_at)
      assert is_nil(updated.import_last_error)
      assert [_] = Library.list_media_files(episode_id: ctx.ep1.id)
      assert [] = Library.list_media_files(episode_id: ctx.ep2.id)
    end

    test "a partial import renames when the library path has auto_rename on", ctx do
      download = pack_download(ctx, %{})

      assert {:ok, :partial} =
               perform_job(
                 MediaImport,
                 partial_args(download, [%{"path" => ctx.ep1_path, "episode_id" => ctx.ep1.id}])
               )

      assert [media_file] = Library.list_media_files(episode_id: ctx.ep1.id)
      name = Path.basename(media_file.relative_path)
      refute name == Path.basename(ctx.ep1_path)
      assert name =~ "Saltmarsh Hollow"
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

    test "full import still places a file whose early import failed", ctx do
      download =
        pack_download(ctx, %{
          status: "completed",
          completed_at: DateTime.utc_now(),
          metadata: %{
            "season_pack" => true,
            "season_number" => 1,
            "episode_count" => 2,
            "early_import_failed_paths" => [ctx.ep2_path]
          }
        })

      stub_status(ctx, [ctx.ep1_path, ctx.ep2_path])

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir
               })

      assert [_] = Library.list_media_files(episode_id: ctx.ep1.id)
      assert [_] = Library.list_media_files(episode_id: ctx.ep2.id)
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

    # A partial job can finish between the full import's first read of the row
    # and its executing? check. The metadata it wrote must still be honoured.
    test "full import rereads the row after the partial check", ctx do
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

      stale =
        Downloads.get_download!(download.id,
          preload: [{:media_item, :episodes}, :episode, :library_path]
        )

      stale = %{stale | metadata: %{"season_pack" => true, "season_number" => 1}}
      raw = %{"download_id" => download.id, "save_path" => ctx.shared_dir, "partial" => false}

      assert {:ok, :imported} =
               MediaImport.perform_with_download(stale, Args.parse(raw), 1, raw)

      updated = Downloads.get_download!(download.id)
      assert %DateTime{} = updated.imported_at
      assert is_nil(updated.match_status)
      assert [] = Library.list_media_files(episode_id: ctx.ep1.id)
      assert [_] = Library.list_media_files(episode_id: ctx.ep2.id)
    end

    test "an early import followed by only unresolved files still finishes", ctx do
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

      # A season with no episode number resolves to nothing, without the
      # episode refresh a missing episode number would trigger.
      stray = Path.join(ctx.shared_dir, "Saltmarsh.Hollow.S01.mkv")
      File.write!(stray, "a stray episode")
      stub_status(ctx, [ctx.ep1_path, stray])

      assert {:ok, :partial_import} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir
               })

      updated = Downloads.get_download!(download.id)
      assert %DateTime{} = updated.imported_at
      assert updated.match_status == "unresolved_files"
      assert is_nil(updated.import_next_retry_at)
      assert StubAdapter.take_removes() == []
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

    # No Oban Lifeline runs here, so a partial job orphaned in `executing` by
    # a crash or restart would otherwise hold the full import off forever.
    test "a partial job left executing from before this node booted does not block the full import",
         ctx do
      booted_at = DateTime.add(DateTime.utc_now(), -60, :second)
      put_booted_at(booted_at)
      download = pack_download(ctx, %{status: "completed", completed_at: DateTime.utc_now()})
      stub_status(ctx, [ctx.ep1_path, ctx.ep2_path])

      insert_executing_job(
        %{"download_id" => download.id, "partial" => true},
        DateTime.add(booted_at, -1, :second)
      )

      refute Partial.executing?(download.id)

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir,
                 "partial" => false
               })
    end

    # A large file can take far longer than a few minutes to copy.
    test "a partial job started after boot holds the full import off however long it runs",
         ctx do
      put_booted_at(DateTime.add(DateTime.utc_now(), -2 * 60 * 60, :second))
      download = pack_download(ctx, %{status: "completed", completed_at: DateTime.utc_now()})

      insert_executing_job(
        %{"download_id" => download.id, "partial" => true},
        DateTime.add(DateTime.utc_now(), -30 * 60, :second)
      )

      assert {:snooze, 30} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir,
                 "partial" => false
               })
    end

    # The :early_import queue's executor is the authority: a row it is running
    # is live whatever its attempted_at says.
    test "an executing partial row the early_import queue is running holds the full import off",
         ctx do
      booted_at = DateTime.add(DateTime.utc_now(), -60, :second)
      put_booted_at(booted_at)
      download = pack_download(ctx, %{status: "completed", completed_at: DateTime.utc_now()})

      job =
        insert_executing_job(
          %{"download_id" => download.id, "partial" => true},
          DateTime.add(booted_at, -1, :second)
        )

      put_running_ids(fn -> {:ok, [job.id]} end)

      assert Partial.executing?(download.id)

      assert {:snooze, 30} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir,
                 "partial" => false
               })
    end

    # A queue restarted inside this node orphans its executing rows without a
    # reboot, so attempted_at alone would hold the full import off forever.
    test "an executing partial row the early_import queue is not running does not block",
         ctx do
      put_booted_at(DateTime.add(DateTime.utc_now(), -2 * 60 * 60, :second))
      download = pack_download(ctx, %{status: "completed", completed_at: DateTime.utc_now()})
      stub_status(ctx, [ctx.ep1_path, ctx.ep2_path])

      job =
        insert_executing_job(
          %{"download_id" => download.id, "partial" => true},
          DateTime.add(DateTime.utc_now(), -30 * 60, :second)
        )

      put_running_ids(fn -> {:ok, [job.id + 1]} end)

      refute Partial.executing?(download.id)

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ctx.shared_dir,
                 "partial" => false
               })
    end

    test "a failed running-jobs lookup falls back to the boot-time rule" do
      booted_at = DateTime.add(DateTime.utc_now(), -60, :second)
      put_booted_at(booted_at)
      live_id = Ecto.UUID.generate()
      orphan_id = Ecto.UUID.generate()

      insert_executing_job(%{"download_id" => live_id, "partial" => true})

      insert_executing_job(
        %{"download_id" => orphan_id, "partial" => true},
        DateTime.add(booted_at, -1, :second)
      )

      for lookup <- [fn -> :error end, fn -> exit(:noproc) end, fn -> raise "registry gone" end] do
        put_running_ids(lookup)

        assert Partial.executing?(live_id)
        refute Partial.executing?(orphan_id)
      end
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
  describe "enqueue/2" do
    # One slot: two partial jobs for a download never copy at once, even when
    # a copy outlasts the unique period.
    test "routes partial jobs to the single-slot early_import queue, full imports stay put" do
      download_id = Ecto.UUID.generate()

      assert {:ok, %Oban.Job{queue: "early_import"}} =
               Partial.enqueue(download_id, [%{"path" => "/x/a.mkv", "episode_id" => nil}])

      full = MediaImport.new(%{"download_id" => download_id})
      assert Ecto.Changeset.get_field(full, :queue) == "default"
    end
  end

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

  # The boot time is global; this module runs async: false.
  defp put_booted_at(booted_at) do
    previous = Mydia.Application.booted_at()
    Mydia.Application.put_booted_at(booted_at)
    on_exit(fn -> Mydia.Application.put_booted_at(previous) end)
  end

  # Stands in for the :early_import queue's executor; this module runs
  # async: false.
  defp put_running_ids(lookup) do
    Application.put_env(:mydia, Partial, running_ids: lookup)
    on_exit(fn -> Application.delete_env(:mydia, Partial) end)
  end

  # Oban stamps attempted_at when it starts a job, so an executing row has one.
  defp insert_executing_job(args, attempted_at \\ DateTime.utc_now()) do
    args
    |> MediaImport.new()
    |> Ecto.Changeset.put_change(:state, "executing")
    |> Ecto.Changeset.put_change(:attempted_at, attempted_at)
    |> Repo.insert!()
  end
end
