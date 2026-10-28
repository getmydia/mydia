defmodule Mydia.Library.LibraryMove.Leftovers do
  @moduledoc """
  Carries what is left in an item's old folders (artwork, `Subs/`, NFOs the
  sidecar rule did not match) into its folder in the target library, then
  prunes the emptied directories.

  A move never `rm_rf`s a source folder: `ItemFolders.finish/1` would delete
  files the item owns that have no row, such as `poster.jpg`. A folder whose
  `ItemFolders.blockers/1` is not empty is left exactly as it is, and so is
  any entry that cannot be carried (its destination exists, or the move
  failed), together with the folder holding it.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Mydia.Jobs.MediaImport.Paths
  alias Mydia.Library.Dirs
  alias Mydia.Library.FileOrganizer
  alias Mydia.Library.ItemFolders
  alias Mydia.Library.ItemFolders.Folder
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Subtitle

  @skip_dirs [".mydia-trash"]

  @doc """
  Handles each folder. `keep` lists absolute paths that must stay where they
  are (sidecars a move left behind with their subtitle rows).
  """
  @spec carry([Folder.t()], MediaItem.t(), LibraryPath.t(), [String.t()]) :: :ok
  def carry(folders, %MediaItem{} = item, %LibraryPath{} = target, keep \\ []) do
    base = Paths.item_destination_dir(item, nil, target, [])
    keep = MapSet.new(keep)
    Enum.each(folders, &carry_folder(&1, base, target, keep))
  end

  # S3 has no directories to prune and no cheap recursive move here, so an S3
  # source folder is left alone: its leftovers stay where they are.
  defp carry_folder(%Folder{absolute: "s3://" <> _}, _base, _target, _keep), do: :ok

  defp carry_folder(%Folder{} = folder, base, target, keep) do
    cond do
      not File.dir?(folder.absolute) ->
        :ok

      ItemFolders.blockers(folder) != [] ->
        Logger.info("Library move kept a source folder: it holds other media",
          path: folder.absolute
        )

      true ->
        dirs = walk(folder.absolute, folder.absolute, base, target, keep)

        dirs
        |> Enum.sort_by(&String.length/1, :desc)
        |> Enum.each(&Dirs.prune_empty(&1, folder.library_path.path))
    end
  end

  # Returns every directory visited, for pruning.
  defp walk(dir, root, base, target, keep) do
    case File.ls(dir) do
      {:ok, names} ->
        nested =
          names
          |> Enum.reject(&(&1 in @skip_dirs))
          |> Enum.flat_map(&visit(Path.join(dir, &1), root, base, target, keep))

        [dir | nested]

      {:error, _} ->
        [dir]
    end
  end

  defp visit(path, root, base, target, keep) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> walk(path, root, base, target, keep)
      {:ok, %{type: :regular}} -> carry_file(path, root, base, target, keep)
      # Symlinks and anything else are never followed or moved.
      _ -> []
    end
  end

  defp carry_file(path, root, base, target, keep) do
    dest = Path.join(base, Path.relative_to(path, root))

    cond do
      MapSet.member?(keep, path) ->
        :ok

      match?({:ok, _}, File.lstat(dest)) ->
        Logger.info("Library move left a file behind: destination exists", path: path)

      true ->
        place(path, dest, target)
    end

    []
  end

  defp place(path, dest, target) do
    case FileOrganizer.place_file(path, dest,
           use_hardlinks: true,
           remove_source_after_hardlink: true,
           fallback: :move,
           confine_to: target.path
         ) do
      {:ok, _} ->
        from(s in Subtitle, where: s.file_path == ^path)
        |> Repo.update_all(set: [file_path: dest])

      {:error, reason} ->
        Logger.warning("Library move could not carry a file", path: path, reason: inspect(reason))
    end
  end
end
