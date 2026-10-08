defmodule Mydia.Jobs.MediaImportS3Test do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  @moduletag :s3
  @moduletag :tmp_dir

  import Ecto.Query
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Jobs.MediaImport
  alias Mydia.Library.MediaFile
  alias Mydia.S3Helpers
  alias Mydia.Settings
  alias Mydia.Storage

  @mib 1024 * 1024

  setup %{tmp_dir: tmp_dir} do
    # A stale directory from an earlier run would hide a regression.
    File.rm_rf!("s3:")

    {library_path, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)

    download_dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(download_dir)

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
    %{library_path: library_path, loc: loc, download_dir: download_dir, movie: movie}
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

  defp run(download, save_path),
    do: perform_job(MediaImport, %{"download_id" => download.id, "save_path" => save_path})

  defp files_in(library_path),
    do: Repo.all(from f in MediaFile, where: f.library_path_id == ^library_path.id)

  test "a completed download is copied into the bucket and the source kept for seeding", ctx do
    source = Path.join(ctx.download_dir, "Invented.Film.2031.mkv")
    File.write!(source, :binary.copy("v", 4096))
    download = download_for(ctx.movie, %{library_path_id: ctx.library_path.id})

    assert {:ok, :imported} = run(download, ctx.download_dir)

    assert [%MediaFile{relative_path: rel, size: 4096}] = files_in(ctx.library_path)
    {:ok, object} = Storage.source(ctx.loc, rel)
    assert {:ok, %{size: 4096}} = Storage.stat(object)
    assert File.exists?(source)
    refute File.exists?("s3:")
  end

  test "an inferred import can land in an S3 library", ctx do
    File.write!(Path.join(ctx.download_dir, "Invented.Film.2031.mkv"), "abc")
    download = download_for(ctx.movie)

    assert {:ok, :imported} = run(download, ctx.download_dir)
    assert [_] = files_in(ctx.library_path)
  end

  test "a file above the part size is uploaded in parts", ctx do
    File.write!(
      Path.join(ctx.download_dir, "Invented.Film.2031.mkv"),
      :binary.copy("p", 11 * @mib)
    )

    download = download_for(ctx.movie, %{library_path_id: ctx.library_path.id})

    assert {:ok, :imported} = run(download, ctx.download_dir)
    [file] = files_in(ctx.library_path)
    {:ok, object} = Storage.source(ctx.loc, file.relative_path)
    assert {:ok, %{size: size}} = Storage.stat(object)
    assert size == 11 * @mib
  end

  test "re-running an import adopts the object it already uploaded", ctx do
    File.write!(Path.join(ctx.download_dir, "Invented.Film.2031.mkv"), "abc")
    download = download_for(ctx.movie, %{library_path_id: ctx.library_path.id})

    assert {:ok, :imported} = run(download, ctx.download_dir)
    Repo.delete_all(MediaFile)

    download = Repo.update!(Ecto.Changeset.change(Repo.reload!(download), imported_at: nil))
    assert {:ok, :imported} = run(download, ctx.download_dir)
    assert [_] = files_in(ctx.library_path)
  end
end
