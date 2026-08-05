defmodule Mydia.Jobs.MediaImportForceTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads
  alias Mydia.Jobs.MediaImport
  alias Mydia.Library
  alias Mydia.Repo
  alias Mydia.Settings

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  @moduletag :tmp_dir

  test "a hand-matched file with a non-video extension is imported", %{tmp_dir: tmp_dir} do
    _library_path = create_test_library_path(tmp_dir, :series)

    download_dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(download_dir)
    obfuscated = Path.join(download_dir, "A1B2C3.bin")
    File.write!(obfuscated, :binary.copy(<<0>>, 4096))

    media_item = media_item_fixture(%{type: "tv_show"})

    episode =
      episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

    # A resolvable download-client config is required to reach
    # `process_import/3` at all: without one, `import_download/2` short-circuits
    # on `{:error, :no_client}` before ever scanning the directory. The host is
    # unreachable on purpose — the fallback to `save_path` is what actually
    # lists the file, exactly as it does in production when the client query
    # fails but a completed torrent's directory is still readable.
    {:ok, _} =
      Settings.create_download_client_config(%{
        name: "ForceImportClient",
        type: :qbittorrent,
        host: "nonexistent.invalid",
        port: 9999,
        username: "test",
        password: "test",
        enabled: true,
        priority: 1
      })

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        status: "completed",
        completed_at: DateTime.utc_now(),
        download_client: "ForceImportClient",
        download_client_id: "force-import-1"
      })

    # The automatic path refuses the file and records what it saw.
    assert {:cancel, :no_importable_files} =
             perform_job(MediaImport, %{
               "download_id" => download.id,
               "save_path" => download_dir
             })

    assert [candidate] = Repo.reload!(download).metadata["import_candidates"]
    assert candidate["skip_reason"] == "not_video_extension"

    # The operator hand-matches the file to the episode.
    assert {:ok, _download} =
             Downloads.resolve_file_mappings(Repo.reload!(download), [
               %{"path" => obfuscated, "episode_id" => episode.id}
             ])

    # The targeted import bypasses the extension filter entirely.
    assert {:ok, :imported} =
             perform_job(MediaImport, %{
               "download_id" => download.id,
               "target_files" => [%{"path" => obfuscated, "episode_id" => episode.id}],
               "use_hardlinks" => true,
               "move_files" => false
             })

    assert Repo.reload!(download).imported_at
    assert [_media_file] = Library.list_media_files(episode_id: episode.id)

    # The hand-matched success must clear the failure-time candidate listing
    # too, not just "unresolved_files" — otherwise a resolved download keeps
    # carrying a stale file listing (and probe verdicts) forever.
    metadata = Repo.reload!(download).metadata
    refute Map.has_key?(metadata, "import_candidates")
    refute Map.has_key?(metadata, "import_candidates_at")
  end

  defp create_test_library_path(base_path, type) do
    library_path = Path.join(base_path, "library")
    File.mkdir_p!(library_path)

    {:ok, path_record} =
      Settings.create_library_path(%{path: library_path, type: type, monitored: true})

    path_record
  end
end
