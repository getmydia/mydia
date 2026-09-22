defmodule Mydia.Library.ItemFolders do
  @moduledoc """
  Finds the folders a media item lives in, and decides whether each can be
  removed when the item is deleted from disk (getmydia/mydia#890).

  A media item stores no folder, so one is derived per file with
  `Mydia.Library.PathAnchor.anchor_for/2`: the folder that names the media,
  above any season, disc, quality or redundant release folder.

  File paths are not proof of ownership. Items often hold files misidentified
  from another show's folder, and a file can sit loose in the library root
  (see "Multi-file items are mostly misidentification" in
  `lib/mydia/media/README.md`). Deleting `Path.dirname/1` of a file would, in
  those cases, delete another show or the whole library. So a folder is only
  removed when `blockers/2` finds nothing media-like in it that is not the
  item's.
  """

  import Ecto.Query

  alias Mydia.Library.Dirs
  alias Mydia.Library.ItemFolders.Folder
  alias Mydia.Library.MediaFile
  alias Mydia.Library.PathAnchor
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  @type blocker :: {:media_file | :import_candidate | :video | :unreadable, String.t()}

  @doc """
  The folders to remove for these media files.

  One anchor per untrashed, non-extra file whose library path is loaded. A
  file loose in the library root has no folder. Duplicates collapse, a folder
  nested inside another one from the list is dropped (the outer one covers
  it), and a folder that is a library path or contains one is refused.
  """
  @spec folders_for([MediaFile.t()]) :: [Folder.t()]
  def folders_for(media_files) when is_list(media_files) do
    roots = library_roots()

    media_files
    |> Enum.filter(&(is_nil(&1.trashed_at) and is_nil(&1.extra_kind)))
    |> Enum.flat_map(&anchor_folder/1)
    |> Enum.uniq_by(& &1.absolute)
    |> drop_nested()
    |> Enum.reject(&holds_library_root?(&1, roots))
  end

  defp anchor_folder(%MediaFile{library_path: %LibraryPath{path: root} = library_path} = file)
       when is_binary(root) do
    with absolute when is_binary(absolute) <- MediaFile.absolute_path(file),
         %{anchor_path: relative} when relative != "" <- PathAnchor.anchor_for(absolute, root) do
      [
        %Folder{
          library_path: library_path,
          relative: relative,
          absolute: Path.join(root, relative)
        }
      ]
    else
      _ -> []
    end
  end

  defp anchor_folder(%MediaFile{}), do: []

  defp drop_nested(folders) do
    Enum.reject(folders, fn folder ->
      Enum.any?(folders, &Dirs.inside?(folder.absolute, &1.absolute))
    end)
  end

  defp holds_library_root?(%Folder{absolute: absolute}, roots) do
    expanded = Path.expand(absolute)
    Enum.any?(roots, &(&1 == expanded or Dirs.inside?(&1, expanded)))
  end

  # Disabled rows count: a disabled library's files are still someone's
  # media. Runtime-configured paths count too, in case one has no row yet.
  defp library_roots do
    db_paths = Repo.all(from(l in LibraryPath, select: l.path))
    runtime_paths = Enum.map(Settings.list_library_paths(), & &1.path)

    (db_paths ++ runtime_paths)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end
end
