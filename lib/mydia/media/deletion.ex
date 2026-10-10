defmodule Mydia.Media.Deletion do
  @moduledoc """
  Owns removing media items, single or in bulk, and the checks and previews around it.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{DiskRemoval, Episode, MediaItem}
  alias Mydia.Events
  alias Mydia.Library.{MediaFile, MediaFileEpisode}

  @doc """
  True when something other than `user_id`'s own bookkeeping depends on the item:
  a media file (movie files carry `media_item_id`, episode files only
  `episode_id`), a download, or another user's progress, collection item or
  request. Used to decide whether an item added moments ago can be withdrawn
  without taking someone else's data or files with it.
  """
  @spec in_use?(MediaItem.t(), binary()) :: boolean()
  def in_use?(%MediaItem{id: id}, user_id) do
    episode_ids = from(e in Episode, where: e.media_item_id == ^id, select: e.id)

    queries = [
      from(f in MediaFile,
        where: f.media_item_id == ^id or f.episode_id in subquery(episode_ids)
      ),
      from(l in MediaFileEpisode, where: l.episode_id in subquery(episode_ids)),
      from(d in Mydia.Downloads.Download,
        where: d.media_item_id == ^id or d.episode_id in subquery(episode_ids)
      ),
      from(p in Mydia.Playback.Progress,
        where:
          p.user_id != ^user_id and
            (p.media_item_id == ^id or p.episode_id in subquery(episode_ids))
      ),
      from(ci in Mydia.Collections.CollectionItem,
        join: c in Mydia.Collections.Collection,
        on: c.id == ci.collection_id,
        where: ci.media_item_id == ^id and c.user_id != ^user_id
      ),
      from(r in Mydia.Media.MediaRequest,
        where: r.media_item_id == ^id and r.requester_id != ^user_id
      )
    ]

    Enum.any?(queries, &Repo.exists?/1)
  end

  @doc """
  Deletes a media item.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:delete_files` - Whether to delete physical files from disk (default: false)

  When `:delete_files` is true, the database records go first, then the
  item's files, the subtitles beside them and every folder of the item that
  holds nothing else are removed from disk. See `Mydia.Media.DiskRemoval`.
  When false (default), only the database records go and every file stays.

  For a TV show, a `:delete_files` of false also demotes every episode's
  files into `import_candidates` first, so they surface again as answerable
  import work if the show is re-added. When `:delete_files` is true, no
  candidates are created for them -- the files are about to be gone, so
  there is nothing left to import.

  The third element describes what happened on disk; it is an empty
  `%DiskRemoval{}` when `:delete_files` is false.
  """
  @spec delete_media_item(Scope.t(), MediaItem.t(), keyword()) ::
          {:ok, MediaItem.t(), DiskRemoval.t()} | {:error, Ecto.Changeset.t()}
  def delete_media_item(%Scope{} = _scope, %MediaItem{} = media_item, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Logger.info("delete_media_item called",
      media_item_id: media_item.id,
      title: media_item.title,
      delete_files: delete_files
    )

    # Plan the disk removal *before* deleting the record, while the rows that
    # name the files, their subtitles and their episodes still exist. The disk
    # is touched only after the delete commits: a failed DB delete then
    # leaves it untouched (nothing lost).
    plan = if delete_files, do: DiskRemoval.plan([media_item.id])

    # Track event before deletion (we need the media_item data)
    actor_type = Keyword.get(opts, :actor_type, :system)
    actor_id = Keyword.get(opts, :actor_id, "media_context")

    Events.media_item_removed(media_item, actor_type, actor_id)

    result =
      Repo.transaction(fn ->
        # When `delete_files` is false, the kept files are parked as
        # dismissed candidates (see `park_media_item_files/1`). When true,
        # episode rows are removed without that side effect because the
        # bytes are about to go: a candidate would be a phantom pointing at
        # a path that no longer exists. The episode media_file rows still
        # have to go before `Repo.delete(media_item)` cascades to the
        # episodes themselves, since `media_files.episode_id` is
        # `ON DELETE NO ACTION`.
        if delete_files do
          delete_media_item_episode_files(media_item)
        else
          park_media_item_files(media_item)
        end

        case Repo.delete(media_item) do
          {:ok, deleted} -> deleted
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, deleted} -> {:ok, deleted, remove_from_disk(plan)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp remove_from_disk(nil), do: %DiskRemoval{}
  defp remove_from_disk(%DiskRemoval.Plan{} = plan), do: DiskRemoval.run(plan)

  @doc """
  What `delete_media_item(media_item, delete_files: true)` would remove from
  disk, for the delete dialog. Read-only and advisory: the delete checks every
  folder again. See `Mydia.Media.DiskRemoval.preview/1`.
  """
  @spec preview_disk_removal(MediaItem.t()) :: DiskRemoval.Preview.t()
  def preview_disk_removal(%MediaItem{} = media_item), do: DiskRemoval.preview(media_item)

  @doc """
  Deletes multiple media items in a transaction.

  ## Options
    - `:delete_files` - Whether to delete physical files from disk (default: false)

  Returns `{:ok, count, %DiskRemoval{}}`, where count is the number of deleted
  items, or `{:error, reason}` if the transaction fails.

  When `:delete_files` is true, the database records are deleted first and
  the items' files and folders are removed from disk after the commit (so a
  failed delete leaves the disk untouched). See `Mydia.Media.DiskRemoval`.
  When false (default), only removes database records and preserves files on
  disk.
  """
  @spec delete_media_items(Scope.t(), [binary()], keyword()) ::
          {:ok, non_neg_integer(), DiskRemoval.t()} | {:error, term()}
  def delete_media_items(%Scope{} = _scope, ids, opts \\ []) when is_list(ids) do
    delete_files = Keyword.get(opts, :delete_files, false)

    # One plan for every item, run once after the commit. Finishing folders
    # item by item would let a second item's not-yet-deleted files keep a
    # folder the two share. See `delete_media_item/2` for why the plan comes
    # before the delete.
    plan = if delete_files, do: DiskRemoval.plan(ids)

    result =
      Repo.transaction(fn ->
        # See the comment in `delete_media_item/2`: parking files as
        # `import_candidates` when they are about to be deleted from disk
        # anyway would leave phantom candidates pointing at paths that no
        # longer exist.
        items =
          MediaItem
          |> where([m], m.id in ^ids)
          |> Repo.all()

        if delete_files do
          items
          |> Enum.filter(&(&1.type == "tv_show"))
          |> Enum.each(&delete_media_item_episode_files/1)
        else
          Enum.each(items, &park_media_item_files/1)
        end

        # Delete the media items (and cascade delete all related DB records).
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.delete_all()
        |> elem(0)
      end)

    case result do
      {:ok, count} -> {:ok, count, remove_from_disk(plan)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Removing an item while keeping its files parks those files as dismissed
  # import candidates: recorded, findable from "Find file" and the dismissed
  # filter on /review, and skipped by every scan, so nothing re-imports what
  # the user removed.
  defp park_media_item_files(%MediaItem{type: "tv_show"} = media_item) do
    Episode
    |> where([episode], episode.media_item_id == ^media_item.id)
    |> Repo.all()
    |> Enum.each(fn episode ->
      case Mydia.ImportCandidates.demote_episode_files(episode, dismiss: true) do
        {:ok, :ok} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp park_media_item_files(%MediaItem{} = media_item) do
    case Mydia.ImportCandidates.demote_movie_files(media_item, dismiss: true) do
      {:ok, :ok} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The `delete_files: true` counterpart to `park_media_item_files/1`:
  # removes the media_file rows for every episode of this show, without
  # creating an `import_candidates` row for any of them. Still has to run
  # before `Repo.delete(media_item)` (or a bulk `Repo.delete_all/1` over
  # `MediaItem`) cascades the delete down to the episodes themselves, since
  # `media_files.episode_id` is `ON DELETE NO ACTION` -- an episode with a
  # media_file still pointing at it cannot be deleted.
  defp delete_media_item_episode_files(%MediaItem{type: "tv_show", id: media_item_id}) do
    episode_ids = from(e in Episode, where: e.media_item_id == ^media_item_id, select: e.id)

    Mydia.Library.MediaFile
    |> where([mf], mf.episode_id in subquery(episode_ids))
    |> Repo.delete_all()

    :ok
  end

  defp delete_media_item_episode_files(%MediaItem{}), do: :ok
end
