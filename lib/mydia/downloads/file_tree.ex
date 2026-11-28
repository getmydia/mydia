defmodule Mydia.Downloads.FileTree do
  @moduledoc """
  Turns a built-in torrent's flat file list into a selectable folder tree, and
  computes selection changes for it. Pure: no client or database access.
  """

  alias Mydia.Downloads.FileTree.{Folder, Leaf}
  alias Mydia.Downloads.Structs.TorrentFile

  @type selection :: MapSet.t(non_neg_integer())
  @type target :: {:folder, String.t()} | {:file, non_neg_integer()}
  @type state :: :all | :none | :partial

  @doc """
  Builds the tree. When every file sits under one top-level folder, that folder
  is the root; otherwise the root is a synthetic folder with `path: ""`.
  """
  @spec build([TorrentFile.t()], selection()) :: Folder.t()
  def build(files, selected) do
    root = build_folder("", "", Enum.map(files, &{String.split(&1.path, "/"), &1}), selected)

    case root.children do
      [%Folder{} = only] -> only
      _ -> root
    end
  end

  @doc "Toggles a file, or every file below a folder, in the selection."
  @spec toggle(selection(), [TorrentFile.t()], target()) :: selection()
  def toggle(selected, _files, {:file, index}) do
    if MapSet.member?(selected, index),
      do: MapSet.delete(selected, index),
      else: MapSet.put(selected, index)
  end

  def toggle(selected, files, {:folder, path}) do
    indexes = for f <- files, String.starts_with?(f.path, path <> "/"), do: f.index

    cond do
      indexes == [] -> selected
      state_of(indexes, selected) == :all -> MapSet.difference(selected, MapSet.new(indexes))
      true -> MapSet.union(selected, MapSet.new(indexes))
    end
  end

  @doc "Selects every file unless all are already selected, then clears."
  @spec toggle_all(selection(), [TorrentFile.t()]) :: selection()
  def toggle_all(selected, files) do
    indexes = Enum.map(files, & &1.index)

    if state_of(indexes, selected) == :all, do: MapSet.new(), else: MapSet.new(indexes)
  end

  @doc "Total bytes of the selected files."
  @spec selected_size([TorrentFile.t()], selection()) :: non_neg_integer()
  def selected_size(files, selected) do
    files |> Enum.filter(&MapSet.member?(selected, &1.index)) |> Enum.map(& &1.size) |> Enum.sum()
  end

  @doc "Selection state of the whole torrent."
  @spec state([TorrentFile.t()], selection()) :: state()
  def state(files, selected), do: state_of(Enum.map(files, & &1.index), selected)

  defp state_of(indexes, selected) do
    count = Enum.count(indexes, &MapSet.member?(selected, &1))

    cond do
      count == 0 -> :none
      count == length(indexes) -> :all
      true -> :partial
    end
  end

  defp build_folder(path, name, entries, selected) do
    {leaves, nested} = Enum.split_with(entries, fn {segments, _} -> match?([_], segments) end)

    folders =
      nested
      |> Enum.group_by(fn {[head | _], _} -> head end, fn {[_ | rest], f} -> {rest, f} end)
      |> Enum.map(fn {segment, sub} ->
        build_folder(join(path, segment), segment, sub, selected)
      end)
      |> Enum.sort_by(&natural_key(&1.name))

    leaf_nodes =
      leaves
      |> Enum.map(fn {[leaf_name], f} ->
        %Leaf{
          index: f.index,
          name: leaf_name,
          size: f.size,
          selected?: MapSet.member?(selected, f.index),
          file: f
        }
      end)
      |> Enum.sort_by(&natural_key(&1.name))

    children = folders ++ leaf_nodes
    size = children |> Enum.map(& &1.size) |> Enum.sum()
    selected_size = children |> Enum.map(&selected_size_of/1) |> Enum.sum()

    %Folder{
      path: path,
      name: name,
      children: children,
      size: size,
      selected_size: selected_size,
      state: folder_state(children)
    }
  end

  defp selected_size_of(%Folder{selected_size: s}), do: s
  defp selected_size_of(%Leaf{selected?: true, size: s}), do: s
  defp selected_size_of(%Leaf{}), do: 0

  defp folder_state(children) do
    states =
      Enum.map(children, fn
        %Folder{state: s} -> s
        %Leaf{selected?: true} -> :all
        %Leaf{} -> :none
      end)

    cond do
      Enum.all?(states, &(&1 == :all)) -> :all
      Enum.all?(states, &(&1 == :none)) -> :none
      true -> :partial
    end
  end

  defp join("", segment), do: segment
  defp join(path, segment), do: path <> "/" <> segment

  defp natural_key(name) do
    ~r/\d+|\D+/
    |> Regex.scan(String.downcase(name))
    |> Enum.map(fn [run] ->
      case Integer.parse(run) do
        {n, ""} -> {0, n, ""}
        _ -> {1, 0, run}
      end
    end)
  end
end
