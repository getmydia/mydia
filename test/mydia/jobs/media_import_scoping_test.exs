defmodule Mydia.Jobs.MediaImportScopingTest do
  @moduledoc """
  Regression coverage for the shared-download-directory contamination bug.

  Clients that keep every torrent in one output folder (rqbit always, and
  qBittorrent for single-file torrents) report that shared folder as the
  download's `save_path`. MediaImport used to recursively list it, so importing
  one episode copied every neighbouring release into that show's library.

  These tests drive the real job through a stub adapter so the per-download
  file list — the fix — is what actually gets exercised.

  `async: false`: the adapter registry is a process-wide Agent.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Jobs.MediaImport
  alias Mydia.Library
  alias Mydia.Settings

  @moduletag :tmp_dir

  # Stub adapter returning whatever status the test stashed in :persistent_term.
  # A stub (rather than a real client) is the point: the previous test for this
  # bug pointed at an unreachable host, so `get_status` failed and the job fell
  # through to the save_path walk without ever touching the scoping code.
  defmodule StubAdapter do
    @behaviour Mydia.Downloads.Client

    def put_status(status), do: :persistent_term.put({__MODULE__, :status}, status)

    @impl true
    def get_status(_config, _client_id) do
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
    def list_torrents(_config, _opts), do: {:ok, []}
    @impl true
    def remove_torrent(_config, _client_id, _opts), do: :ok
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
    @impl true
    def supported_protocols, do: [:torrent]
  end

  setup do
    previous = Registry.lookup(:rqbit)
    Registry.register(:rqbit, StubAdapter)

    on_exit(fn ->
      :persistent_term.erase({StubAdapter, :status})
      if previous, do: Registry.register(:rqbit, previous)
    end)

    :ok
  end

  describe "per-download file list" do
    test "imports only the download's own file out of a shared directory", ctx do
      %{library_root: library_root, shared_dir: shared_dir} = setup_shared_dir(ctx.tmp_dir)

      own = Path.join(shared_dir, "Silo.S01E01.Pilot.1080p.mkv")
      neighbour = Path.join(shared_dir, "Star.Trek.TOS.S01E01.The.Man.Trap.mkv")
      File.write!(own, "silo video payload")
      File.write!(neighbour, "star trek video payload")

      {media_item, episode} = tv_fixture("Silo", 2023)

      client = client_fixture("ScopedClient")

      # save_path is the shared root — exactly what rqbit reports for a
      # single-file torrent — but `files` names only this torrent's file.
      StubAdapter.put_status(status(client_id: "scoped-1", save_path: shared_dir, files: [own]))

      download = download_for(media_item, episode, client, "scoped-1")

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => shared_dir
               })

      assert [imported] = media_files_for(episode)
      assert imported.relative_path =~ "Silo"

      refute Enum.any?(library_files(library_root), &(Path.basename(&1) =~ "Star.Trek")),
             "neighbouring torrent's file must not be copied into the library"
    end

    test "recurses a multi-file torrent's own directory but not its siblings", ctx do
      %{library_root: library_root, shared_dir: shared_dir} = setup_shared_dir(ctx.tmp_dir)

      own_dir = Path.join(shared_dir, "Silo.S01.1080p-GROUP")
      File.mkdir_p!(own_dir)
      File.write!(Path.join(own_dir, "Silo.S01E01.Pilot.mkv"), "silo e1")

      neighbour_dir = Path.join(shared_dir, "Star.Trek.TOS.S01.1080p-GROUP")
      File.mkdir_p!(neighbour_dir)
      File.write!(Path.join(neighbour_dir, "Star.Trek.TOS.S01E01.mkv"), "trek e1")

      {media_item, episode} = tv_fixture("Silo", 2023)
      client = client_fixture("ScopedPackClient")

      StubAdapter.put_status(
        status(client_id: "scoped-2", save_path: shared_dir, files: [own_dir])
      )

      download = download_for(media_item, episode, client, "scoped-2")

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => shared_dir
               })

      assert [_] = media_files_for(episode)

      refute Enum.any?(library_files(library_root), &(Path.basename(&1) =~ "Star.Trek"))
    end

    test "refuses the save_path walk when the scoped files are missing", ctx do
      %{library_root: library_root, shared_dir: shared_dir} = setup_shared_dir(ctx.tmp_dir)

      # The client's file list points somewhere Mydia cannot see (an unmapped
      # remote path). Falling back to walking the shared root here would sweep
      # in the neighbour — the regression this guards.
      File.write!(Path.join(shared_dir, "Star.Trek.TOS.S01E01.mkv"), "trek e1")

      {media_item, episode} = tv_fixture("Silo", 2023)
      client = client_fixture("MissingFilesClient")

      StubAdapter.put_status(
        status(
          client_id: "scoped-3",
          save_path: shared_dir,
          files: [Path.join(shared_dir, "Silo.S01E01.gone.mkv")]
        )
      )

      download = download_for(media_item, episode, client, "scoped-3")

      assert {:error, {:scoped_files_missing, 1}} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => shared_dir
               })

      assert media_files_for(episode) == []
      assert library_files(library_root) == []
    end
  end

  describe "save_path fallback" do
    test "refuses a save_path that is the client's configured download root", ctx do
      %{library_root: library_root, shared_dir: shared_dir} = setup_shared_dir(ctx.tmp_dir)

      File.write!(Path.join(shared_dir, "Star.Trek.TOS.S01E01.mkv"), "trek e1")

      {media_item, episode} = tv_fixture("Silo", 2023)
      client = client_fixture("RootClient", download_directory: shared_dir)

      # No status at all, so the job drops to the save_path fallback.
      download = download_for(media_item, episode, client, "scoped-4")

      # Terminal, not retried: the client config will report the same root on
      # every attempt, so this needs an operator, not a retry budget.
      assert {:cancel, {:save_path_is_download_root, ^shared_dir}} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => shared_dir
               })

      assert library_files(library_root) == []
    end

    test "still walks a save_path that is a per-download subfolder", ctx do
      %{library_root: _library_root, shared_dir: shared_dir} = setup_shared_dir(ctx.tmp_dir)

      own_dir = Path.join(shared_dir, "Silo.S01E01.1080p-GROUP")
      File.mkdir_p!(own_dir)
      File.write!(Path.join(own_dir, "Silo.S01E01.Pilot.mkv"), "silo e1")
      File.write!(Path.join(shared_dir, "Star.Trek.TOS.S01E01.mkv"), "trek e1")

      {media_item, episode} = tv_fixture("Silo", 2023)
      client = client_fixture("SubfolderClient", download_directory: shared_dir)

      download = download_for(media_item, episode, client, "scoped-5")

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => own_dir
               })

      assert [_] = media_files_for(episode)
    end
  end

  ## Helpers

  defp setup_shared_dir(tmp_dir) do
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

  defp client_fixture(name, opts \\ []) do
    {:ok, client} =
      Settings.create_download_client_config(
        Enum.into(opts, %{
          name: name,
          type: :rqbit,
          host: "localhost",
          port: 3030,
          enabled: true,
          priority: 1
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
      state: :completed,
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

  defp media_files_for(episode) do
    Library.list_media_files() |> Enum.filter(&(&1.episode_id == episode.id))
  end

  defp library_files(library_root) do
    library_root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end
end
