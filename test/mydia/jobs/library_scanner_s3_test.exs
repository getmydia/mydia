defmodule Mydia.Jobs.LibraryScannerS3Test do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library
  alias Mydia.Settings
  import Mydia.MediaFixtures

  test "an unreachable S3 backend fails the scan and trashes nothing" do
    bypass = Bypass.open()

    {:ok, _} =
      Settings.create_storage_backend(%{
        name: "m",
        endpoint: "http://localhost:#{bypass.port}",
        region: "us-east-1",
        bucket: "lib",
        access_key_id: "k",
        secret_access_key: "s"
      })

    {:ok, library_path} =
      Settings.create_library_path(%{path: "s3://m/movies", type: "movies", monitored: true})

    files =
      for name <- ["a.mkv", "b.mkv"] do
        media_file_fixture(%{
          library_path_id: library_path.id,
          media_item_id: media_item_fixture(%{type: "movie"}).id,
          relative_path: "Invented Film (2031)/#{name}"
        })
      end

    Bypass.down(bypass)

    assert {:error, _} = perform_job(LibraryScanner, %{"library_path_id" => library_path.id})

    updated = Settings.get_library_path!(library_path.id)
    assert updated.last_scan_status == :failed
    assert updated.last_scan_error =~ "cannot reach storage"

    for f <- files do
      assert Library.get_media_file!(f.id).trashed_at == nil
    end
  end
end
