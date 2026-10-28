defmodule Mydia.Library.FileMoveTest do
  use Mydia.DataCase, async: false

  @moduletag :tmp_dir

  alias Mydia.Library.FileMove
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  setup %{tmp_dir: tmp} do
    src_root = Path.join(tmp, "a")
    dst_root = Path.join(tmp, "b")
    File.mkdir_p!(src_root)
    File.mkdir_p!(dst_root)
    src = library_path_fixture(%{type: "movies", path: src_root})
    dst = library_path_fixture(%{type: "movies", path: dst_root})
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    rel = "Glass Harbor (2019)/glass.mkv"
    abs = Path.join(src_root, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "video")

    file =
      media_file_fixture(%{
        media_item_id: movie.id,
        library_path_id: src.id,
        relative_path: rel,
        size: 5
      })
      |> Repo.preload(:library_path, force: true)

    %{src: src, dst: dst, mf: file, abs: abs, rel: rel}
  end

  test "place, relink, cleanup moves the file and the row", %{
    dst: dst,
    mf: file,
    abs: abs,
    rel: rel
  } do
    dest = Path.join(dst.path, rel)
    assert {:ok, _} = FileMove.place(file, dest, dst)
    assert {:ok, updated} = FileMove.relink(file, dst, rel, %{}, &{:ok, &1})
    assert :ok = FileMove.cleanup_source(abs, dest)

    assert updated.library_path_id == dst.id
    assert File.read!(dest) == "video"
    refute File.exists?(abs)
  end

  test "place refuses to overwrite an untracked file", %{dst: dst, mf: file, rel: rel} do
    dest = Path.join(dst.path, rel)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, "someone else's bytes")

    assert {:error, :conflict} = FileMove.place(file, dest, dst)
    assert File.read!(dest) == "someone else's bytes"
  end

  test "relink aborts when the row moved meanwhile", %{dst: dst, mf: file, rel: rel} do
    Repo.update!(Ecto.Changeset.change(file, relative_path: "elsewhere.mkv"))
    assert {:error, :media_file_moved} = FileMove.relink(file, dst, rel, %{}, &{:ok, &1})
  end

  test "relink rolls back when after_update fails", %{dst: dst, mf: file, rel: rel} do
    assert {:error, :boom} = FileMove.relink(file, dst, rel, %{}, fn _ -> {:error, :boom} end)
    assert Repo.get!(MediaFile, file.id).library_path_id == file.library_path_id
  end

  for {name, opts} <- [hardlink: [], copy: [use_hardlinks: false]] do
    test "a retry after a failed relink adopts the earlier #{name}", %{
      dst: dst,
      mf: file,
      rel: rel
    } do
      opts = unquote(opts)
      dest = Path.join(dst.path, rel)

      assert {:ok, _} = FileMove.place(file, dest, dst, opts)
      assert {:error, :boom} = FileMove.relink(file, dst, rel, %{}, fn _ -> {:error, :boom} end)

      assert {:ok, _} = FileMove.place(file, dest, dst, opts)
      assert {:ok, _} = FileMove.relink(file, dst, rel, %{}, &{:ok, &1})
      assert File.read!(dest) == "video"
    end
  end

  test "a stale partial sibling does not block a copy", %{dst: dst, mf: file, rel: rel} do
    dest = Path.join(dst.path, rel)
    partial = Path.join(Path.dirname(dest), ".#{Path.basename(dest)}.mydia-partial")
    File.mkdir_p!(Path.dirname(dest))
    File.write!(partial, "tru")

    assert {:ok, :copy} = FileMove.place(file, dest, dst, use_hardlinks: false)
    assert File.read!(dest) == "video"
    refute File.exists?(partial)
  end

  test "a same-size file with different content is a conflict", %{dst: dst, mf: file, rel: rel} do
    dest = Path.join(dst.path, rel)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, "other")

    assert {:error, :conflict} = FileMove.place(file, dest, dst)
    assert File.read!(dest) == "other"
  end

  test "a destination outside the library is a path escape", %{dst: dst, mf: file, tmp_dir: tmp} do
    assert {:error, {:path_escape, _}} = FileMove.place(file, Path.join(tmp, "out.mkv"), dst)
  end
end
