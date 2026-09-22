defmodule Mydia.Media.DiskRemoval do
  @moduledoc """
  Removes deleted media items from disk: their files, the subtitles beside
  them, and each of their folders that holds nothing else
  (getmydia/mydia#890).

  `Mydia.Media.delete_media_item/2` and `delete_media_items/2` call `plan/1`
  before the record delete, while the rows that name the files still exist,
  and `run/1` after it commits: a failed record delete leaves the disk
  untouched, and nothing on disk could be rolled back anyway.

  The struct is the result, returned by the delete functions.
  """

  import Ecto.Query
  require Logger

  alias Mydia.Library
  alias Mydia.Library.Dirs
  alias Mydia.Library.ItemFolders
  alias Mydia.Library.MediaFile
  alias Mydia.Media.DiskRemoval.Plan
  alias Mydia.Media.DiskRemoval.Preview
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Subtitle

  defstruct files_failed: 0, folders_removed: [], folders_kept: []

  @type kept_reason :: {:blocked, [ItemFolders.blocker()]} | {:error, File.posix()}

  @type t :: %__MODULE__{
          files_failed: non_neg_integer(),
          folders_removed: [String.t()],
          folders_kept: [{String.t(), kept_reason()}]
        }

  @doc """
  Everything `run/1` needs, read before the rows go.

  The files are every row whose `media_item_id` is one of the items (movie
  files) or whose `episode_id` is one of their episodes, with or without a
  `media_file_episodes` link. A file linked to one of their episodes only
  through that join has its primary episode in another show, so it is that
  show's file and stays. Trashed rows are included: their row goes with the
  item, as it always did.
  """
  @spec plan([binary()]) :: Plan.t()
  def plan(media_item_ids) when is_list(media_item_ids) do
    query = files_query(media_item_ids)
    files = query |> preload(:library_path) |> Repo.all()

    %Plan{
      files: files,
      subtitle_paths: subtitle_paths(files, query),
      folders: ItemFolders.folders_for(files)
    }
  end

  defp files_query(media_item_ids) do
    episode_ids = from(e in Episode, where: e.media_item_id in ^media_item_ids, select: e.id)

    from(mf in MediaFile,
      where: mf.media_item_id in ^media_item_ids or mf.episode_id in subquery(episode_ids)
    )
  end

  # Only a subtitle beside its own video is removed. A row can point anywhere
  # (an extraction cache, for one), and nothing outside the item's
  # directories is this delete's to touch.
  defp subtitle_paths(files, files_query) do
    dirs = Map.new(files, &{&1.id, video_dir(&1)})
    file_ids = select(files_query, [mf], mf.id)

    from(s in Subtitle,
      where: s.media_file_id in subquery(file_ids) and not is_nil(s.file_path),
      select: {s.media_file_id, s.file_path}
    )
    |> Repo.all()
    |> Enum.filter(fn {id, path} -> dirs[id] != nil and Path.dirname(path) == dirs[id] end)
    |> Enum.group_by(fn {id, _path} -> id end, fn {_id, path} -> path end)
  end

  defp video_dir(file) do
    case MediaFile.absolute_path(file) do
      nil -> nil
      path -> Path.dirname(path)
    end
  end

  @doc """
  Deletes the planned files (each video and its `.nfo`), the subtitles of
  the ones that went, then each folder `Mydia.Library.ItemFolders.finish/1`
  finds nothing else in, then prunes the directories the deletes emptied.

  Call it only after the rows are gone: `finish/1` treats anything still
  under a folder as someone else's. A file of the item that could not be
  deleted is still on disk, so it keeps its own folder.
  """
  @spec run(Plan.t()) :: t()
  def run(%Plan{} = plan) do
    results = Enum.map(plan.files, &{&1, Library.delete_media_file_from_disk(&1)})
    removed = for {file, :ok} <- results, do: file

    Enum.each(removed, fn file ->
      plan.subtitle_paths |> Map.get(file.id, []) |> Enum.each(&delete_subtitle/1)
    end)

    outcomes = Enum.map(plan.folders, &ItemFolders.finish/1)
    Enum.each(removed, &prune_after/1)

    result = %__MODULE__{
      files_failed: Enum.count(results, &match?({_file, {:error, _}}, &1)),
      folders_removed: for({:removed, path} <- outcomes, do: path),
      folders_kept: for({:kept, path, reason} <- outcomes, do: {path, reason})
    }

    Logger.info("Removed deleted media from disk",
      files: length(removed),
      files_failed: result.files_failed,
      folders_removed: length(result.folders_removed),
      folders_kept: length(result.folders_kept)
    )

    result
  end

  defp delete_subtitle(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete subtitle file", path: path, reason: inspect(reason))
    end
  end

  # A no-op inside a removed folder: its directories are already gone.
  defp prune_after(%MediaFile{library_path: %LibraryPath{path: root}} = file)
       when is_binary(root) do
    case MediaFile.absolute_path(file) do
      nil -> :ok
      path -> Dirs.prune_empty(Path.dirname(path), root)
    end
  end

  defp prune_after(_file), do: :ok

  @doc """
  What deleting `media_item` from disk would do, without doing any of it:
  the folders that would go, the folders that would stay and what keeps
  them, and how many files sit outside every folder.
  """
  @spec preview(MediaItem.t()) :: Preview.t()
  def preview(%MediaItem{id: id}) do
    plan = plan([id])

    outcomes =
      Enum.map(plan.folders, fn folder ->
        {folder.absolute, ItemFolders.blockers(folder, ignore: plan.files)}
      end)

    %Preview{
      remove: for({path, []} <- outcomes, do: path),
      keep: for({path, [_ | _] = blockers} <- outcomes, do: {path, blockers}),
      loose_files: Enum.count(plan.files, &loose?(&1, plan.folders))
    }
  end

  defp loose?(%MediaFile{trashed_at: nil} = file, folders) do
    case MediaFile.absolute_path(file) do
      nil -> false
      path -> not Enum.any?(folders, &Dirs.inside?(path, &1.absolute))
    end
  end

  defp loose?(_file, _folders), do: false
end
