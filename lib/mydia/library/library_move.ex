defmodule Mydia.Library.LibraryMove do
  @moduledoc """
  Moves a media item, with all of its files, into another library.

  `plan/2` says where each file would go: where an import into the target
  library would put it (`Mydia.Jobs.MediaImport.Paths`), so a moved item
  looks like it was always there. Extras keep their place under the item's
  folder.
  """

  import Ecto.Query

  alias Mydia.Jobs.MediaImport.Paths
  alias Mydia.Library.Dirs
  alias Mydia.Library.ItemFolders
  alias Mydia.Library.LibraryMove.Move
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @spec plan(MediaItem.t(), LibraryPath.t()) :: {:ok, [Move.t()]}
  def plan(%MediaItem{} = media_item, %LibraryPath{} = target) do
    files = item_files(media_item.id)
    folders = ItemFolders.folders_for(files)

    moves =
      files
      |> Enum.reject(&(&1.library_path_id == target.id))
      |> Enum.map(&plan_file(&1, media_item, target, folders))
      |> Enum.reject(&is_nil/1)

    {:ok, moves}
  end

  @doc """
  The item's untrashed files: rows on the item itself (movie files) or whose
  primary episode is one of its episodes. Same ownership rule as
  `Mydia.Media.DiskRemoval`; the `media_file_episodes` join is not ownership.
  """
  @spec item_files(binary()) :: [MediaFile.t()]
  def item_files(media_item_id) do
    episode_ids = from(e in Episode, where: e.media_item_id == ^media_item_id, select: e.id)

    from(mf in MediaFile,
      where: mf.media_item_id == ^media_item_id or mf.episode_id in subquery(episode_ids),
      where: is_nil(mf.trashed_at),
      preload: [:library_path, :episode]
    )
    |> Repo.all()
  end

  defp plan_file(file, media_item, target, folders) do
    case MediaFile.storage_path(file) do
      nil ->
        nil

      source ->
        rel = dest_rel(file, media_item, target, folders)

        %Move{
          media_file: file,
          source_path: source,
          dest_path: Path.join(target.path, rel),
          dest_rel: rel,
          action: action(source, target)
        }
    end
  end

  defp dest_rel(%MediaFile{extra_kind: nil} = file, media_item, target, _folders) do
    dir = Paths.item_destination_dir(media_item, file.episode, target, [])
    rename? = target.auto_rename || false
    basename = Path.basename(file.relative_path)
    name = Paths.item_filename(media_item, file.episode, basename, rename?, nil)
    Path.relative_to(Path.join(dir, name), target.path)
  end

  defp dest_rel(file, media_item, target, folders) do
    base = Paths.item_destination_dir(media_item, nil, target, [])
    Path.relative_to(Path.join(base, extra_tail(file, folders)), target.path)
  end

  # Where the extra sits under its item's folder, so Featurettes/ survives.
  # The item folders come from its main files: an extra's own anchor would be
  # the Featurettes folder itself. A loose extra falls back to its own anchor,
  # then to its basename.
  defp extra_tail(file, folders) do
    source = MediaFile.storage_path(file)

    case Enum.find(folders, &Dirs.inside?(source, &1.absolute)) || ItemFolders.folder_of(file) do
      %{absolute: anchor} -> Path.relative_to(source, anchor)
      nil -> Path.basename(source)
    end
  end

  defp action("s3://" <> _, _target), do: :copy
  defp action(_source, %LibraryPath{path: "s3://" <> _}), do: :copy

  defp action(source, target) do
    with {:ok, %{major_device: a}} <- File.stat(source),
         {:ok, %{major_device: b}} <- File.stat(existing_ancestor(target.path)) do
      if a == b, do: :hardlink, else: :copy
    else
      _ -> :copy
    end
  end

  defp existing_ancestor(path) do
    parent = Path.dirname(path)
    if File.exists?(path) or parent == path, do: path, else: existing_ancestor(parent)
  end
end
