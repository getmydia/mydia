defmodule Mydia.Library.LibraryMove do
  @moduledoc """
  Moves a media item, with all of its files, into another library.

  `plan/2` says where each file would go: where an import into the target
  library would put it (`Mydia.Jobs.MediaImport.Paths`), so a moved item
  looks like it was always there. Extras keep their place under the item's
  folder.

  `enqueue/3` and `enqueue_many/3` start a move (see `LibraryMove.Enqueue`);
  `Mydia.Jobs.LibraryMove` carries it out and calls `record_event/4`.
  """

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.Jobs.MediaImport.Paths
  alias Mydia.Library.Dirs
  alias Mydia.Library.FileMove
  alias Mydia.Library.ItemFolders
  alias Mydia.Library.LibraryMove.Enqueue
  alias Mydia.Library.LibraryMove.Move
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath
  alias Mydia.Settings.RuntimeConfig

  @preview_examples 5

  @doc """
  Points `media_item` at `target` and enqueues the job that moves its files.
  Refuses with `:disabled_library`, `:incompatible_library`, `:already_there`,
  `:import_in_progress` (an import or re-match of one of its downloads is
  pending) or `:move_in_progress` (a move of this item is already queued).
  The event's actor is `scope.user`, or the system when there is none.
  """
  @spec enqueue(MediaItem.t(), LibraryPath.t(), Scope.t()) ::
          {:ok, Oban.Job.t()} | {:error, Enqueue.error()}
  defdelegate enqueue(media_item, target, scope), to: Enqueue

  @doc "`enqueue/3` for each item: the number enqueued and each refusal."
  @spec enqueue_many([MediaItem.t()], LibraryPath.t(), Scope.t()) ::
          {non_neg_integer(), [{MediaItem.t(), Enqueue.error()}]}
  defdelegate enqueue_many(media_items, target, scope), to: Enqueue

  @doc """
  Enabled libraries that can hold every one of `media_items`, in the order of
  `Settings.list_library_paths/0`. Libraries defined only by environment
  variables have no row an item can point at, so they are left out.
  """
  @spec compatible_targets([MediaItem.t()]) :: [LibraryPath.t()]
  def compatible_targets(media_items) do
    Settings.list_library_paths()
    |> Enum.reject(&(&1.disabled || RuntimeConfig.runtime_config?(&1)))
    |> Enum.filter(fn target -> Enum.all?(media_items, &Enqueue.compatible?(&1, target)) end)
  end

  @doc """
  What a move of `media_item` into `target` would do, for a confirmation
  dialog. `skipped` counts files that would collide with another file of the
  item at the destination; they are left out of every other count.
  """
  @spec preview(MediaItem.t(), LibraryPath.t()) :: %{
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          hardlink: non_neg_integer(),
          copy: non_neg_integer(),
          skipped: non_neg_integer(),
          examples: [{String.t(), String.t()}]
        }
  def preview(%MediaItem{} = media_item, %LibraryPath{} = target) do
    {:ok, planned} = plan(media_item, target)
    {skipped, moves} = Enum.split_with(planned, & &1.conflict)

    %{
      files: length(moves),
      skipped: length(skipped),
      bytes: moves |> Enum.map(&(&1.media_file.size || 0)) |> Enum.sum(),
      hardlink: Enum.count(moves, &(&1.action == :hardlink)),
      copy: Enum.count(moves, &(&1.action == :copy)),
      examples:
        moves
        |> Enum.take(@preview_examples)
        |> Enum.map(&{&1.media_file.relative_path, &1.dest_rel})
    }
  end

  @doc """
  Records how the move of `media_item` into `target` stands. The counts come
  from the item's files now, not from one attempt: `moved` is how many are in
  `target`, `skipped` how many are not. `target` is nil when the library no
  longer exists; `failed: true` marks a move that was called off.
  `requested_by` is the user who asked, kept in the metadata.
  """
  @spec record_event(MediaItem.t(), LibraryPath.t() | nil, binary() | nil, keyword()) :: :ok
  def record_event(media_item, target, requested_by, opts \\ []) do
    media_item
    |> event_attrs(target, requested_by, opts)
    |> Mydia.Events.create_event_async()
  end

  @doc false
  def event_attrs(media_item, target, requested_by, opts \\ []) do
    files = item_files(media_item.id)
    moved = Enum.count(files, &(target && &1.library_path_id == target.id))
    skipped = length(files) - moved
    failed? = Keyword.get(opts, :failed, false) or (moved == 0 and skipped > 0)

    %{
      category: "media",
      type: if(failed?, do: "media_item.library_move_failed", else: "media_item.library_moved"),
      actor_type: :job,
      actor_id: "library_move",
      resource_type: "media_item",
      resource_id: media_item.id,
      severity: if(failed? or skipped > 0, do: :warning, else: :info),
      metadata:
        maybe_put(
          %{
            "title" => media_item.title,
            "media_type" => media_item.type,
            "library" => library_name(target),
            "moved" => moved,
            "skipped" => skipped
          },
          "requested_by",
          requested_by
        )
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp library_name(%LibraryPath{} = target), do: LibraryPath.display_name(target)
  defp library_name(nil), do: nil

  @spec plan(MediaItem.t(), LibraryPath.t()) :: {:ok, [Move.t()]}
  def plan(%MediaItem{} = media_item, %LibraryPath{} = target) do
    files = item_files(media_item.id)
    folders = ItemFolders.folders_for(files)

    moves =
      files
      |> Enum.reject(&(&1.library_path_id == target.id))
      |> Enum.map(&plan_file(&1, media_item, target, folders))
      |> Enum.reject(&is_nil/1)
      |> mark_conflicts(target)

    {:ok, moves}
  end

  # A destination claimed by any other row, live or trashed (a trashed row
  # keeps its relative_path while its bytes sit in the trash), or planned for
  # an earlier file is skipped: relink would otherwise delete that row. The
  # job re-plans on every attempt, so this holds at perform time too.
  defp mark_conflicts(moves, target) do
    {marked, _taken} =
      Enum.map_reduce(moves, MapSet.new(), fn move, taken ->
        conflict =
          MapSet.member?(taken, move.dest_rel) or
            FileMove.claimed?(target.id, move.dest_rel, move.media_file.id)

        {%{move | conflict: conflict}, MapSet.put(taken, move.dest_rel)}
      end)

    marked
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
