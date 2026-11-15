defmodule Mydia.Downloads.EarlyImportTest do
  @moduledoc """
  `ready_targets/2` is pure: it judges an `EnrichedDownload` as given.
  `run/1` fetches a fresh status for candidates because the list endpoint
  of rqbit carries no per-file progress.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query

  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.EarlyImport
  alias Mydia.Downloads.Structs.{DownloadStatus, EnrichedDownload}
  alias Mydia.Repo
  alias Mydia.Settings

  defmodule StubAdapter do
    @behaviour Mydia.Downloads.Client

    def put_status(status), do: :persistent_term.put({__MODULE__, :status}, status)
    def calls, do: :persistent_term.get({__MODULE__, :calls}, 0)

    @impl true
    def get_status(_config, _client_id) do
      :persistent_term.put({__MODULE__, :calls}, calls() + 1)

      case :persistent_term.get({__MODULE__, :status}, nil) do
        nil -> {:error, :not_found}
        status -> {:ok, status}
      end
    end

    @impl true
    def test_connection(_config), do: {:error, :not_implemented}
    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:error, :not_implemented}
    @impl true
    def remove_torrent(_config, _id, _opts), do: :ok
    @impl true
    def list_torrents(_config, _opts), do: {:ok, []}
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
    @impl true
    def supported_protocols, do: [:torrent]
  end

  defp all_exist, do: fn _ -> true end

  defp entry(index, have, length \\ 100),
    do: %{index: index, path: "/dl/Pack/e0#{index}.mkv", length: length, have: have}

  defp download(overrides \\ %{}) do
    struct!(
      EnrichedDownload,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          title: "Pack",
          download_client: "RqEarly",
          download_client_id: "rq-1",
          status: "downloading",
          metadata: %{"file_episodes" => %{"0" => "ep-a", "1" => "ep-b"}},
          file_progress: [entry(0, 100), entry(1, 40)]
        },
        overrides
      )
    )
  end

  describe "ready_targets/2" do
    test "returns a complete file with its episode id" do
      assert [%{"path" => "/dl/Pack/e00.mkv", "episode_id" => "ep-a"}] =
               EarlyImport.ready_targets(download(), all_exist())
    end

    test "excludes incomplete files" do
      d = download(%{file_progress: [entry(0, 99), entry(1, 40)]})
      assert EarlyImport.ready_targets(d, all_exist()) == []
    end

    test "excludes paths already early imported" do
      d =
        download(%{
          metadata: %{
            "file_episodes" => %{"0" => "ep-a", "1" => "ep-b"},
            "early_imported_paths" => ["/dl/Pack/e00.mkv"]
          }
        })

      assert EarlyImport.ready_targets(d, all_exist()) == []
    end

    test "excludes paths whose early import failed" do
      d =
        download(%{
          metadata: %{
            "file_episodes" => %{"0" => "ep-a", "1" => "ep-b"},
            "early_import_failed_paths" => ["/dl/Pack/e00.mkv"]
          }
        })

      assert EarlyImport.ready_targets(d, all_exist()) == []
    end

    test "applies the path mapping before checking and recording a path" do
      map = fn "/dl/" <> rest -> "/local/" <> rest end
      local_only = &String.starts_with?(&1, "/local/")

      assert [%{"path" => "/local/Pack/e00.mkv", "episode_id" => "ep-a"}] =
               EarlyImport.ready_targets(download(), local_only, map)

      imported =
        download(%{
          metadata: %{
            "file_episodes" => %{"0" => "ep-a", "1" => "ep-b"},
            "early_imported_paths" => ["/local/Pack/e00.mkv"]
          }
        })

      assert EarlyImport.ready_targets(imported, local_only, map) == []
    end

    test "excludes files with no file_episodes entry" do
      d = download(%{metadata: %{"file_episodes" => %{"1" => "ep-b"}}})
      assert EarlyImport.ready_targets(d, all_exist()) == []
    end

    test "excludes paths missing on this host" do
      assert EarlyImport.ready_targets(download(), fn _ -> false end) == []
    end

    test "is empty for a single included file" do
      d = download(%{file_progress: [entry(0, 100)]})
      assert EarlyImport.ready_targets(d, all_exist()) == []
    end

    test "is empty without file_progress or when not downloading" do
      assert EarlyImport.ready_targets(download(%{file_progress: nil}), all_exist()) == []
      assert EarlyImport.ready_targets(download(%{status: "completed"}), all_exist()) == []
    end
  end

  describe "run/1" do
    setup do
      previous = Registry.lookup(:rqbit)
      Registry.register(:rqbit, StubAdapter)
      :persistent_term.erase({StubAdapter, :calls})
      :persistent_term.erase({StubAdapter, :status})

      on_exit(fn ->
        :persistent_term.erase({StubAdapter, :status})
        :persistent_term.erase({StubAdapter, :calls})
        if previous, do: Registry.register(:rqbit, previous)
      end)

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "RqEarly",
          type: :rqbit,
          host: "localhost",
          port: 3030,
          enabled: true,
          priority: 1
        })

      :ok
    end

    defp partial_jobs do
      Repo.all(from(j in Oban.Job, where: j.worker == "Mydia.Jobs.MediaImport"))
      |> Enum.filter(&(&1.args["partial"] == true))
    end

    defp status_with(progress, tmp) do
      DownloadStatus.new(%{
        id: "rq-1",
        name: "stub",
        state: :downloading,
        progress: 50.0,
        download_speed: 0,
        upload_speed: 0,
        downloaded: 0,
        uploaded: 0,
        size: 0,
        eta: nil,
        ratio: 0.0,
        save_path: tmp,
        files: [],
        file_progress: progress,
        added_at: nil,
        completed_at: nil
      })
    end

    @tag :tmp_dir
    test "fetches fresh status and enqueues one partial job", %{tmp_dir: tmp} do
      path = Path.join(tmp, "e00.mkv")
      File.write!(path, "x")
      other = Path.join(tmp, "e01.mkv")
      File.write!(other, "x")

      StubAdapter.put_status(
        status_with(
          [
            %{index: 0, path: path, length: 100, have: 100},
            %{index: 1, path: other, length: 100, have: 3}
          ],
          tmp
        )
      )

      db = Mydia.DownloadsFixtures.download_fixture(%{status: "downloading"})
      d = download(%{id: db.id, file_progress: nil})

      assert :ok = EarlyImport.run([d])

      assert [job] = partial_jobs()
      assert job.args["download_id"] == db.id
      assert job.args["target_files"] == [%{"path" => path, "episode_id" => "ep-a"}]
    end

    test "costs no request without file_episodes" do
      d = download(%{file_progress: nil, metadata: %{}})
      assert :ok = EarlyImport.run([d])
      assert StubAdapter.calls() == 0
      assert partial_jobs() == []
    end

    test "swallows a get_status error" do
      d = download(%{file_progress: nil})
      assert :ok = EarlyImport.run([d])
      assert partial_jobs() == []
    end

    test "swallows an unresolvable client" do
      d = download(%{file_progress: nil, download_client: "Nope"})
      assert :ok = EarlyImport.run([d])
      assert partial_jobs() == []
    end
  end
end
