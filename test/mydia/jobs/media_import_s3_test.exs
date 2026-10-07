defmodule Mydia.Jobs.MediaImportS3Test do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MediaImport
  alias Mydia.Repo
  alias Mydia.Settings

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # A stale directory from an earlier run would hide a regression.
    File.rm_rf!("s3:")

    {:ok, _} =
      Settings.create_storage_backend(%{
        name: "media",
        endpoint: "http://localhost:1",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    {:ok, s3_library} =
      Settings.create_library_path(%{path: "s3://media/movies", type: :movies, monitored: true})

    download_dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(download_dir)
    File.write!(Path.join(download_dir, "Invented.Film.2031.mkv"), :binary.copy(<<0>>, 4096))

    {:ok, _} =
      Settings.create_download_client_config(%{
        name: "S3ImportClient",
        type: :qbittorrent,
        host: "nonexistent.invalid",
        port: 9999,
        username: "test",
        password: "test",
        enabled: true,
        priority: 1
      })

    movie = media_item_fixture(%{type: "movie", title: "Invented Film", year: 2031})

    %{s3_library: s3_library, download_dir: download_dir, movie: movie}
  end

  defp download_for(movie, attrs \\ %{}) do
    download_fixture(
      Map.merge(
        %{
          media_item_id: movie.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "S3ImportClient",
          download_client_id: "s3-import-1"
        },
        attrs
      )
    )
  end

  defp run(download, download_dir),
    do: perform_job(MediaImport, %{"download_id" => download.id, "save_path" => download_dir})

  test "an inferred import never lands in an S3 library", %{
    download_dir: download_dir,
    movie: movie
  } do
    download = download_for(movie)

    assert {:error, :no_library_path} = run(download, download_dir)
    refute File.exists?("s3:")
    assert Repo.reload!(download).imported_at == nil
  end

  test "an S3 download override fails read-only before touching the filesystem", %{
    s3_library: s3_library,
    download_dir: download_dir,
    movie: movie
  } do
    download = download_for(movie, %{library_path_id: s3_library.id})

    # Terminal: a read-only library never becomes writable by retrying, and a
    # pending retry would keep the download occupying its target.
    assert {:cancel, :library_read_only} = run(download, download_dir)
    refute File.exists?("s3:")

    reloaded = Repo.reload!(download)
    assert reloaded.import_last_error =~ "read-only"
    assert reloaded.import_next_retry_at == nil
    assert reloaded.import_failure_reason == "library_read_only"
  end
end
