defmodule Mydia.Library.DeleteS3Test do
  use Mydia.DataCase, async: false

  @moduletag :s3

  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.{ImportCandidates, Library, Media}
  alias Mydia.Library.{ItemFolders, MediaFile}
  alias Mydia.S3Helpers
  alias Mydia.Storage

  setup do
    {lp, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    %{lp: lp, loc: loc}
  end

  defp exists?(loc, rel) do
    {:ok, src} = Storage.source(loc, rel)
    Storage.exists?(src)
  end

  test "deleting a media file with delete_files removes the object and its NFO", %{
    lp: lp,
    loc: loc
  } do
    S3Helpers.put_object!(loc, "Invented Film (2031)/film.mkv", "v")
    S3Helpers.put_object!(loc, "Invented Film (2031)/film.nfo", "<movie/>")

    file =
      media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Invented Film (2031)/film.mkv"
      })

    assert {:ok, _} = Library.delete_media_file(Repo.get!(MediaFile, file.id), delete_files: true)
    refute exists?(loc, "Invented Film (2031)/film.mkv")
    refute exists?(loc, "Invented Film (2031)/film.nfo")
  end

  test "deleting an item removes its folder prefix when nothing else is in it", %{
    lp: lp,
    loc: loc
  } do
    S3Helpers.put_object!(loc, "Invented Film (2031)/film.mkv", "v")
    S3Helpers.put_object!(loc, "Invented Film (2031)/poster.jpg", "p")
    S3Helpers.put_object!(loc, "Invented Film (2031) Other/x.mkv", "o")
    item = media_item_fixture(%{type: "movie", title: "Invented Film", year: 2031})

    media_file_fixture(%{
      library_path_id: lp.id,
      media_item_id: item.id,
      relative_path: "Invented Film (2031)/film.mkv"
    })

    assert {:ok, _, _} = Media.delete_media_item(Scope.unrestricted(), item, delete_files: true)

    refute exists?(loc, "Invented Film (2031)/poster.jpg")
    assert exists?(loc, "Invented Film (2031) Other/x.mkv")
  end

  test "a folder holding another video is kept", %{lp: lp, loc: loc} do
    S3Helpers.put_object!(loc, "Invented Film (2031)/film.mkv", "v")
    S3Helpers.put_object!(loc, "Invented Film (2031)/unrelated.mkv", "u")

    file =
      media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Invented Film (2031)/film.mkv"
      })

    [folder] =
      ItemFolders.folders_for([Repo.preload(Repo.get!(MediaFile, file.id), :library_path)])

    # The item's own file is gone from the bucket and the database before
    # the folder is finished, as in DiskRemoval.run/1.
    Repo.delete!(Repo.get!(MediaFile, file.id))
    {:ok, src} = Storage.source(loc, "Invented Film (2031)/film.mkv")
    :ok = Storage.delete(src)

    assert {:kept, _, {:blocked, [{:video, "Invented Film (2031)/unrelated.mkv"}]}} =
             ItemFolders.finish(folder)
  end

  test "a queued candidate delete removes the object", %{lp: lp, loc: loc} do
    S3Helpers.put_object!(loc, "Loose/film.mkv", "v")

    import_candidate_fixture(%{
      library_path_id: lp.id,
      relative_path: "Loose/film.mkv",
      size: 1,
      queued_op: "delete"
    })

    assert {:ok, %{deleted: 1, failed: 0}} = ImportCandidates.drain_delete(lp.id)
    refute exists?(loc, "Loose/film.mkv")
  end
end
