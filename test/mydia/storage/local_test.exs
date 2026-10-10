defmodule Mydia.Storage.LocalTest do
  use ExUnit.Case, async: true
  use Mydia.StorageContractCase

  alias Mydia.Storage.Location

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "lib")
    File.mkdir_p!(root)
    %{location: Location.local(root), root: root}
  end

  test "put_binary/3 without mkdir never creates a missing directory", %{location: loc} do
    {:ok, src} = Mydia.Storage.source(loc, "absent/dir/film.nfo")

    assert {:error, %Mydia.Storage.Error{kind: :not_found}} =
             Mydia.Storage.put_binary(src, "x")

    refute File.exists?(Path.join(loc.root, "absent"))
  end

  test "a non-exclusive put_binary/3 leaves no .tmp file behind", %{location: loc, root: root} do
    {:ok, src} = Mydia.Storage.source(loc, "film.nfo")
    assert :ok = Mydia.Storage.put_binary(src, "x")
    assert File.ls!(root) == ["film.nfo"]
  end

  def put_fixture(%{root: root}, rel, bin) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bin)
  end

  test "input/1 is the absolute path", %{location: loc, root: root} = ctx do
    put_fixture(ctx, "x.mkv", "1")
    {:ok, source} = Mydia.Storage.source(loc, "x.mkv")
    assert {:ok, path} = Mydia.Storage.input(source)
    assert path == Path.join(root, "x.mkv")
  end

  test "validate/1 maps a missing root to :not_found" do
    assert {:error, %Mydia.Storage.Error{kind: :not_found}} =
             Mydia.Storage.validate(Location.local("/definitely/not/here"))
  end

  describe "copy_file/2" do
    test "copies the bytes and the source's mode", %{tmp_dir: dir} do
      src = Path.join(dir, "src.mkv")
      dest = Path.join(dir, "dest.mkv")
      File.write!(src, "bytes")
      File.chmod!(src, 0o640)

      assert :ok = Mydia.Storage.Local.copy_file(src, dest)
      assert File.read!(dest) == "bytes"
      assert Bitwise.band(File.stat!(dest).mode, 0o777) == 0o640
    end

    test "overwrites an existing destination", %{tmp_dir: dir} do
      src = Path.join(dir, "src.mkv")
      dest = Path.join(dir, "dest.mkv")
      File.write!(src, "new")
      File.write!(dest, "old and longer")

      assert :ok = Mydia.Storage.Local.copy_file(src, dest)
      assert File.read!(dest) == "new"
    end

    test "returns the posix error when the source is missing", %{tmp_dir: dir} do
      assert {:error, :enoent} =
               Mydia.Storage.Local.copy_file(Path.join(dir, "absent"), Path.join(dir, "dest"))
    end
  end
end
