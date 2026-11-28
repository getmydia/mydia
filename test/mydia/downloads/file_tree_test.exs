defmodule Mydia.Downloads.FileTreeTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.FileTree
  alias Mydia.Downloads.FileTree.{Folder, Leaf}
  alias Mydia.Downloads.Structs.TorrentFile

  @s1 "The.Lantern.Keepers.S01"
  @s2 "The.Lantern.Keepers.S02"

  defp file(index, path, size), do: %TorrentFile{index: index, path: path, size: size}

  defp files do
    [
      file(0, "#{@s1}/E01.mkv", 100),
      file(1, "#{@s1}/E02.mkv", 100),
      file(2, "#{@s2}/E10.mkv", 50),
      file(3, "#{@s2}/E9.mkv", 50),
      file(4, "readme.nfo", 1)
    ]
  end

  defp folder(root, name), do: Enum.find(root.children, &(&1.name == name))

  test "nests by path and totals sizes" do
    root = FileTree.build(files(), MapSet.new())
    assert %Folder{size: 301, path: ""} = root
    assert %Folder{size: 200} = folder(root, @s1)
  end

  test "folders sort before files, natural order" do
    root = FileTree.build(files(), MapSet.new())
    assert Enum.map(root.children, & &1.name) == [@s1, @s2, "readme.nfo"]
    assert Enum.map(folder(root, @s2).children, & &1.name) == ["E9.mkv", "E10.mkv"]
    assert %Leaf{index: 4} = List.last(root.children)
  end

  test "a single top-level folder becomes the root" do
    root = FileTree.build(Enum.take(files(), 2), MapSet.new())
    assert %Folder{path: @s1, name: @s1} = root
    assert Enum.map(root.children, & &1.name) == ["E01.mkv", "E02.mkv"]
  end

  test "folder states" do
    root = FileTree.build(files(), MapSet.new([0, 1, 2]))
    assert folder(root, @s1).state == :all
    assert folder(root, @s2).state == :partial
    assert folder(root, @s2).selected_size == 50
    assert root.state == :partial

    root = FileTree.build(files(), MapSet.new())
    assert folder(root, @s1).state == :none
    assert FileTree.selected_size(files(), MapSet.new([0, 1, 2])) == 250
    assert FileTree.state(files(), MapSet.new([0, 1, 2])) == :partial
    assert FileTree.state(files(), MapSet.new(0..4)) == :all
    assert FileTree.state(files(), MapSet.new()) == :none
  end

  test "toggling a partial or empty folder selects it, a full one clears it" do
    sel = FileTree.toggle(MapSet.new([2]), files(), {:folder, @s2})
    assert sel == MapSet.new([2, 3])
    assert FileTree.toggle(sel, files(), {:folder, @s2}) == MapSet.new([])
  end

  test "toggling a file flips it" do
    sel = FileTree.toggle(MapSet.new(), files(), {:file, 4})
    assert sel == MapSet.new([4])
    assert FileTree.toggle(sel, files(), {:file, 4}) == MapSet.new()
  end

  test "toggle_all selects all unless all are selected" do
    all = MapSet.new(0..4)
    assert FileTree.toggle_all(MapSet.new([1]), files()) == all
    assert FileTree.toggle_all(all, files()) == MapSet.new()
  end

  test "a folder path that matches no files leaves the selection unchanged" do
    sel = MapSet.new([1])
    assert FileTree.toggle(sel, files(), {:folder, "nope"}) == sel
  end
end
