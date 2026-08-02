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
  alias Mydia.Library.TrashStore
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

  # The end-to-end cross-filesystem move needs a second filesystem, but the
  # contract that matters is in this one two-argument function: it is the only
  # place in the trash path that can delete the copy that just succeeded.
  describe "remove_source_after_copy/2" do
    @tag :tmp_dir
    test "keeps the copy when the source vanished mid-move", %{tmp_dir: tmp_dir} do
      # File.cp/2 succeeded, then something else removed the source before we
      # got to it. The goal state - bytes at the destination, nothing at the
      # library path - has been reached, so the copy must survive.
      source = Path.join(tmp_dir, "gone.mkv")
      destination = Path.join(tmp_dir, "copy.mkv")
      File.write!(destination, "video bytes")

      assert TrashStore.remove_source_after_copy(source, destination) == :ok
      assert File.read!(destination) == "video bytes"
    end

    @tag :tmp_dir
    test "removes the source and keeps the copy in the ordinary case", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "orig.mkv")
      destination = Path.join(tmp_dir, "moved.mkv")
      File.write!(source, "video bytes")
      File.write!(destination, "video bytes")

      assert TrashStore.remove_source_after_copy(source, destination) == :ok
      refute File.exists?(source)
      assert File.read!(destination) == "video bytes"
    end
  end

  describe "root_for/1" do
    test "falls back inside the library when the library path is a mount root" do
      # A library at /media or /data (both common in Docker) has "/" as its
      # parent, so the sibling default would put the trash on the container's
      # writable layer - a different filesystem at best, an unwritable
      # read-only rootfs at worst, in which case every trash fails. Staying
      # inside the library keeps the move an atomic rename; the scanner's
      # .mydia-trash skip is what makes that safe.
      library_path = library_path_fixture(%{path: "/mydia_mount_root", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "movie.mkv",
          library_path_id: library_path.id,
          size: 1
        })

      media_file = Repo.preload(media_file, :library_path)

      assert TrashStore.root_for(media_file) == "/mydia_mount_root/.mydia-trash"
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

    # Re-review: restore into an occupied destination deliberately does not
    # clobber what is there, but it used to drop trashed_path anyway, leaving
    # the copy under .mydia-trash/<id>/ with nothing referencing it - never
    # restorable, never purged. The pointer has to survive so the bytes stay
    # reclaimable.
    @tag :tmp_dir
    test "keeps the trash pointer when the library path is already occupied", %{tmp_dir: tmp_dir} do
      {_root, media_file, path} = library_with_file(tmp_dir)

      {:ok, trashed} = Library.trash_media_file(media_file)
      trashed_path = trashed.metadata.extra["trashed_path"]

      File.write!(path, "something else")

      assert {:ok, restored} = Library.restore_media_file(trashed)

      assert is_nil(restored.trashed_at)
      assert File.read!(path) == "something else"
      assert File.exists?(trashed_path)
      assert restored.metadata.extra["trashed_path"] == trashed_path
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

    # Re-review finding A (CRITICAL). trash_media_file/1 records nothing for a
    # row whose file was already missing, which is exactly what
    # LibraryScanner's deleted_files batch produces when a network share is
    # unmounted mid-scan and the whole library reads as deleted. If the share
    # comes back and no rescan runs - and the rescan that would restore those
    # rows is opt-in per library path, so it is not guaranteed - the daily
    # TrashCleanup must not treat those rows like pre-TrashStore rows and
    # delete the entire library from the library path 30 days later.
    @tag :tmp_dir
    test "leaves the file alone when the row was trashed while it was missing", %{
      tmp_dir: tmp_dir
    } do
      {_root, media_file, path} = library_with_file(tmp_dir)

      # The share goes away, a scan trashes the row.
      File.rm!(path)
      {:ok, trashed} = Library.trash_media_file(media_file)

      # The share comes back, but nothing rescans.
      File.write!(path, "video bytes")
      backdate(trashed)

      assert {:ok, 1} = Library.purge_old_trashed_media_files(30)

      assert File.read!(path) == "video bytes"
    end

    @tag :tmp_dir
    test "leaves the NFO alone when the row was trashed while the file was missing", %{
      tmp_dir: tmp_dir
    } do
      {_root, media_file, path} = library_with_file(tmp_dir)
      nfo = Path.rootname(path) <> ".nfo"
      File.write!(nfo, "<movie/>")

      File.rm!(path)
      {:ok, trashed} = Library.trash_media_file(media_file)
      backdate(trashed)

      assert {:ok, 1} = Library.purge_old_trashed_media_files(30)

      assert File.exists?(nfo)
    end

    # Copilot review: the purge used to drop every expired row whether or not
    # its bytes actually went away, because `discard/2` swallowed the error.
    # A file under `.mydia-trash/<id>/` with no row pointing at it is one
    # nothing can restore or purge, so the space was gone for good and no
    # later run retried. Keeping the row is what makes the retry possible.
    #
    # The delete is forced to fail with a directory at the trashed path:
    # `unlink` refuses a directory for any uid, so this holds when the suite
    # runs as root, which a permissions-based test would not.
    @tag :tmp_dir
    test "keeps the row when the trashed file cannot be deleted", %{tmp_dir: tmp_dir} do
      {_root, media_file, _path} = library_with_file(tmp_dir)

      {:ok, trashed} = Library.trash_media_file(media_file)
      trashed_path = trashed.metadata.extra["trashed_path"]
      backdate(trashed)

      File.rm!(trashed_path)
      File.mkdir_p!(trashed_path)
      File.write!(Path.join(trashed_path, "undeletable"), "x")

      assert {:ok, 0} = Library.purge_old_trashed_media_files(30)

      # The row survives, so the next purge tries again.
      assert %{} = kept = Library.get_media_file(media_file.id)
      refute is_nil(kept.trashed_at)
      assert File.exists?(trashed_path)
    end

    @tag :tmp_dir
    test "purges normally when the trashed file is already gone from disk", %{tmp_dir: tmp_dir} do
      {_root, media_file, _path} = library_with_file(tmp_dir)

      {:ok, trashed} = Library.trash_media_file(media_file)
      trashed_path = trashed.metadata.extra["trashed_path"]
      backdate(trashed)

      # Someone emptied the trash by hand. The goal state is already reached,
      # so this must not be mistaken for a failed delete and retried forever.
      File.rm!(trashed_path)

      assert {:ok, 1} = Library.purge_old_trashed_media_files(30)
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
