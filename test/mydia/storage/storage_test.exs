defmodule Mydia.StorageTest do
  use Mydia.DataCase, async: false

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias Mydia.Storage
  alias Mydia.Storage.Error

  @moduletag :tmp_dir

  test "source/1 and media_input/1 for a local file", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.mkv"), "x")
    mf = %MediaFile{relative_path: "a.mkv", library_path: %LibraryPath{path: dir}}

    assert {:ok, %{path: path}} = Storage.source(mf)
    assert path == Path.join(dir, "a.mkv")
    assert {:ok, ^path} = Storage.media_input(mf)

    assert {:error, %Error{kind: :not_found}} =
             Storage.media_input(%{mf | relative_path: "gone.mkv"})
  end

  test "an unloaded library_path is an error, not a crash" do
    mf = %MediaFile{relative_path: "a.mkv", library_path: %Ecto.Association.NotLoaded{}}
    assert {:error, %Error{}} = Storage.source(mf)
  end

  test "absolute_path/1 is nil for S3 files" do
    mf = %MediaFile{relative_path: "a.mkv", library_path: %LibraryPath{path: "s3://media/m"}}
    assert MediaFile.absolute_path(mf) == nil
  end

  test "ensure_writable/1" do
    assert :ok = Storage.ensure_writable(%LibraryPath{path: "/data"})

    assert {:error, %Error{kind: :read_only}} =
             Storage.ensure_writable(%LibraryPath{path: "s3://m/x"})

    assert {:error, %Error{kind: :read_only}} = Storage.ensure_writable("s3://m/x/file.mkv")
    assert :ok = Storage.ensure_writable(nil)
  end
end
