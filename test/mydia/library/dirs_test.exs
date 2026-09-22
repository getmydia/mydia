defmodule Mydia.Library.DirsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Dirs

  describe "inside?/2" do
    test "a child is inside its root" do
      assert Dirs.inside?("/media/tv/Tin Kettle", "/media/tv")
    end

    test "a sibling that shares the root's prefix is not inside it" do
      refute Dirs.inside?("/media/tv2/Tin Kettle", "/media/tv")
    end

    test "a root is not inside itself" do
      refute Dirs.inside?("/media/tv", "/media/tv")
      refute Dirs.inside?("/media/tv/", "/media/tv")
    end

    test "a trailing slash on the root changes nothing" do
      assert Dirs.inside?("/media/tv/Tin Kettle", "/media/tv/")
    end
  end

  describe "prune_empty/2" do
    @describetag :tmp_dir

    test "removes empty directories up to, and never including, the root", %{tmp_dir: tmp} do
      deep = Path.join(tmp, "Tin Kettle/Season 01")
      File.mkdir_p!(deep)

      assert :ok = Dirs.prune_empty(deep, tmp)

      refute File.exists?(Path.join(tmp, "Tin Kettle"))
      assert File.dir?(tmp)
    end

    test "stops at the first directory that is not empty", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "Tin Kettle/Season 01"))
      File.write!(Path.join(tmp, "Tin Kettle/poster.jpg"), "art")

      Dirs.prune_empty(Path.join(tmp, "Tin Kettle/Season 01"), tmp)

      refute File.exists?(Path.join(tmp, "Tin Kettle/Season 01"))
      assert File.exists?(Path.join(tmp, "Tin Kettle/poster.jpg"))
    end

    test "never touches a directory outside the root that shares its prefix", %{tmp_dir: tmp} do
      root = Path.join(tmp, "tv")
      sibling = Path.join(tmp, "tv2/Empty")
      File.mkdir_p!(root)
      File.mkdir_p!(sibling)

      Dirs.prune_empty(sibling, root)

      assert File.dir?(sibling)
    end

    test "a directory that does not exist is a no-op", %{tmp_dir: tmp} do
      assert :ok = Dirs.prune_empty(Path.join(tmp, "gone/deeper"), tmp)
    end
  end
end
