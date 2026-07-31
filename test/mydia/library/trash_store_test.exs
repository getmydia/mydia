defmodule Mydia.Library.TrashStoreTest do
  @moduledoc """
  Whole-branch review finding 1 (CRITICAL): trashing only stamped `trashed_at`
  and left the file on the library path, so the next scan classified it as a
  new file and restored the row - reverting every automatic upgrade and
  resurrecting every rejected release.
  """
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.Scanner
  alias Mydia.Repo

  setup do
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)
    :ok
  end

  defp library_with_file(tmp_dir, name \\ "movie.mkv") do
    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    path = Path.join(root, name)
    File.write!(path, "video bytes")

    library_path = library_path_fixture(%{path: root, type: "movies"})

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: library_path.id,
        size: byte_size("video bytes")
      })

    {root, Repo.preload(media_file, :library_path), path}
  end

  describe "trash_media_file/1 on disk" do
    @tag :tmp_dir
    test "moves the file off the library path", %{tmp_dir: tmp_dir} do
      {_root, media_file, path} = library_with_file(tmp_dir)

      {:ok, trashed} = Library.trash_media_file(media_file)

      refute File.exists?(path)
      trashed_path = trashed.metadata.extra["trashed_path"]
      assert is_binary(trashed_path)
      assert File.read!(trashed_path) == "video bytes"
    end

    @tag :tmp_dir
    test "defaults the trash root to a sibling of the library path", %{tmp_dir: tmp_dir} do
      {_root, media_file, _path} = library_with_file(tmp_dir)

      {:ok, trashed} = Library.trash_media_file(media_file)

      assert trashed.metadata.extra["trashed_path"] ==
               Path.join([tmp_dir, ".mydia-trash", media_file.id, "movie.mkv"])
    end

    @tag :tmp_dir
    test "a rescan no longer sees the trashed file", %{tmp_dir: tmp_dir} do
      {root, media_file, _path} = library_with_file(tmp_dir)

      {:ok, _trashed} = Library.trash_media_file(media_file)

      {:ok, scan} = Scanner.scan(root)
      assert scan.files == []
    end

    @tag :tmp_dir
    test "keeps the row untrashed when the file cannot be moved", %{tmp_dir: tmp_dir} do
      {_root, media_file, path} = library_with_file(tmp_dir)

      # A regular file where the trash root should be: mkdir_p cannot create
      # the container directory, so the move fails before anything is touched.
      blocker = Path.join(tmp_dir, "blocked")
      File.write!(blocker, "not a directory")
      Application.put_env(:mydia, :trash_dir, blocker)

      assert {:error, _reason} = Library.trash_media_file(media_file)

      assert File.exists?(path)
      assert is_nil(Repo.reload!(media_file).trashed_at)
    end

    @tag :tmp_dir
    test "still trashes a row whose file is already gone", %{tmp_dir: tmp_dir} do
      {_root, media_file, path} = library_with_file(tmp_dir)
      File.rm!(path)

      assert {:ok, trashed} = Library.trash_media_file(media_file)
      assert trashed.trashed_at
      assert is_nil(trashed.metadata.extra["trashed_path"])
    end
  end

  describe "restore_media_file/1 on disk" do
    @tag :tmp_dir
    test "moves the file back to the library path", %{tmp_dir: tmp_dir} do
      {_root, media_file, path} = library_with_file(tmp_dir)

      {:ok, trashed} = Library.trash_media_file(media_file)
      trashed_path = trashed.metadata.extra["trashed_path"]

      {:ok, restored} = Library.restore_media_file(trashed)

      assert is_nil(restored.trashed_at)
      assert is_nil(restored.metadata.extra["trashed_path"])
      assert File.read!(path) == "video bytes"
      refute File.exists?(trashed_path)
    end

    @tag :tmp_dir
    test "copes with the trashed copy being gone", %{tmp_dir: tmp_dir} do
      {_root, media_file, _path} = library_with_file(tmp_dir)

      {:ok, trashed} = Library.trash_media_file(media_file)
      File.rm!(trashed.metadata.extra["trashed_path"])

      assert {:ok, restored} = Library.restore_media_file(trashed)
      assert is_nil(restored.trashed_at)
    end
  end

  describe "purge_old_trashed_media_files/1 on disk" do
    @tag :tmp_dir
    test "deletes the trashed file from disk", %{tmp_dir: tmp_dir} do
      {_root, media_file, _path} = library_with_file(tmp_dir)

      {:ok, trashed} = Library.trash_media_file(media_file)
      trashed_path = trashed.metadata.extra["trashed_path"]
      backdate(trashed)

      assert {:ok, 1} = Library.purge_old_trashed_media_files(30)

      refute File.exists?(trashed_path)
      assert is_nil(Library.get_media_file(media_file.id))
    end

    @tag :tmp_dir
    test "deletes a legacy trashed file still sitting in the library", %{tmp_dir: tmp_dir} do
      # Issue #295: rows trashed before the file moved off the library path.
      {_root, media_file, path} = library_with_file(tmp_dir)

      trashed =
        media_file
        |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update!()

      backdate(trashed)

      assert {:ok, 1} = Library.purge_old_trashed_media_files(30)
      refute File.exists?(path)
    end
  end

  defp backdate(media_file) do
    media_file
    |> Ecto.Changeset.change(
      trashed_at: DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end
end
