defmodule Mydia.Library.FileRenamerS3Test do
  use Mydia.DataCase, async: false

  @moduletag :s3

  import Mydia.MediaFixtures

  alias Mydia.Library.{FileRenamer, MediaFile}
  alias Mydia.S3Helpers
  alias Mydia.Storage

  setup do
    {lp, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    S3Helpers.put_object!(loc, "Invented Film (2031)/old.mkv", "bytes")

    file =
      media_file_fixture(%{library_path_id: lp.id, relative_path: "Invented Film (2031)/old.mkv"})

    %{lp: lp, loc: loc, mf: Repo.get!(MediaFile, file.id)}
  end

  test "renames the object and the row", %{lp: lp, loc: loc, mf: file} do
    new_path = Path.join(lp.path, "Invented Film (2031)/Invented Film (2031).mkv")

    assert {:ok, renamed} = FileRenamer.rename_file(file, new_path)
    assert renamed.relative_path == "Invented Film (2031)/Invented Film (2031).mkv"

    {:ok, old} = Storage.source(loc, "Invented Film (2031)/old.mkv")
    {:ok, new} = Storage.source(loc, renamed.relative_path)
    refute Storage.exists?(old)
    assert {:ok, "bytes"} = Storage.read(new)
  end

  test "refuses an occupied target and leaves both objects", %{lp: lp, loc: loc, mf: file} do
    S3Helpers.put_object!(loc, "Invented Film (2031)/taken.mkv", "other")

    assert {:error, :target_exists} =
             FileRenamer.rename_file(file, Path.join(lp.path, "Invented Film (2031)/taken.mkv"))

    {:ok, old} = Storage.source(loc, "Invented Film (2031)/old.mkv")
    assert Storage.exists?(old)
  end

  test "a missing object is :file_not_found", %{lp: lp, loc: loc, mf: file} do
    {:ok, old} = Storage.source(loc, "Invented Film (2031)/old.mkv")
    :ok = Storage.delete(old)

    assert {:error, :file_not_found} =
             FileRenamer.rename_file(file, Path.join(lp.path, "Invented Film (2031)/new.mkv"))
  end

  test "rename previews resolve S3 paths", %{lp: lp, mf: file} do
    preview = FileRenamer.generate_rename_preview(file)

    assert String.starts_with?(preview.current_path, "s3://")
    assert preview.current_path == lp.path <> "/Invented Film (2031)/old.mkv"
  end
end
