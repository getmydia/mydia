defmodule Mydia.LibraryApi.RevisionFeed do
  @moduledoc """
  The latest-state revision feed over `media_item_revisions`.

  One row per media item ever observed, ordered by the database-generated
  `revision` and paged strictly after a boundary from
  `Mydia.LibraryApi.RevisionCursor`. Repeated changes coalesce into the item's
  single marker, and a deletion leaves a tombstone (`deleted: true`) instead of
  removing the row, so a consumer that resumes past the deletion still learns
  about it.

  `changed_at` is the time of an item's latest representation change, which is
  why the API sources `MediaItem.updatedAt` from it through `changed_at!/1`.
  Nothing here orders by a wall clock.
  """

  import Ecto.Query

  alias Mydia.DB
  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.Repo

  @doc """
  Lists markers oldest revision first.

  Options: `:limit` (required) and `:after`, a revision from
  `Mydia.LibraryApi.RevisionCursor.decode/1`; the page starts strictly after it.
  Tombstones are included, because a deletion is a change a consumer has to
  learn about.
  """
  @spec list(keyword()) :: [MediaItemRevision.t()]
  def list(opts) do
    MediaItemRevision
    |> after_revision(Keyword.get(opts, :after))
    |> order_by([r], asc: r.revision)
    |> limit(^Keyword.fetch!(opts, :limit))
    |> Repo.all()
  end

  defp after_revision(query, nil), do: query

  defp after_revision(query, revision) when is_integer(revision) do
    where(query, [r], r.revision > ^revision)
  end

  @doc """
  Maps each live media-item id to the `changed_at` of its marker.

  Unknown and tombstoned ids are absent from the map, so a caller reading this
  for a page of results never reports a deleted item's timestamp. Batched
  callers use this; a caller with one item uses `changed_at!/1`.
  """
  @spec changed_at_by_ids([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => DateTime.t()}
  def changed_at_by_ids([]), do: %{}

  def changed_at_by_ids(ids) do
    MediaItemRevision
    |> where([r], r.media_item_id in ^ids and not r.deleted)
    |> select([r], {r.media_item_id, r.changed_at})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The `changed_at` of one live media item's marker.

  Raises `Ecto.NoResultsError` when the id has no marker or only a tombstone.
  Every observable write advances a marker, so a live item without one is a
  broken invariant, not an absent value.
  """
  @spec changed_at!(Ecto.UUID.t()) :: DateTime.t()
  def changed_at!(media_item_id) do
    MediaItemRevision
    |> Repo.get_by!(media_item_id: media_item_id, deleted: false)
    |> Map.fetch!(:changed_at)
  end

  @doc """
  Advances the live marker of each given media-item id, for the UTC-day clock
  sweep only.

  A clock-derived status change (`UPCOMING` becoming `AVAILABLE` at a UTC date
  boundary) writes no row for a trigger to observe, so the sweep names the
  affected items here. Ids are deduplicated, an empty list is a no-op that runs
  no SQL, and an id whose media item no longer exists is ignored rather than
  resurrecting its tombstone.

  Do not route normal writes through this: they already advance their item
  through the triggers. This exists only for clock transitions, and it applies
  the same database-allocated, greater-revision upsert the triggers use.
  """
  @spec mark_live([Ecto.UUID.t()]) :: :ok
  def mark_live(ids) when is_list(ids) do
    case Enum.uniq(ids) do
      [] -> :ok
      unique -> mark_live_rows(unique)
    end
  end

  # PostgreSQL goes through the migration's own mark-live helper, so the
  # existence check and the upsert guard stay defined in one place. Each id is
  # cast from text explicitly: an uncast parameter in a uuid position is
  # described as uuid, and Postgrex encodes that type from 16-byte binaries only,
  # never from the 36-character strings the caller holds.
  #
  # SQLite has no stored function, so this repeats the trigger's INSERT ...
  # SELECT shape: one attempted row per live item, and `excluded.revision` is the
  # AUTOINCREMENT value the database allocated for the conflict update.
  defp mark_live_rows(ids) do
    if DB.postgres?() do
      values =
        ids
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {_id, index} -> "($#{index}::text)" end)

      Repo.query!(
        """
        SELECT mydia_library_revision_mark_live(ids.id::uuid)
        FROM (VALUES #{values}) AS ids(id)
        """,
        ids
      )
    else
      placeholders = ids |> Enum.map_join(", ", fn _id -> "?" end)

      Repo.query!(
        """
        INSERT INTO media_item_revisions (media_item_id, deleted)
        SELECT m.id, 0
        FROM media_items AS m
        WHERE m.id IN (#{placeholders})
        ON CONFLICT (media_item_id) DO UPDATE SET
          revision = excluded.revision,
          deleted = excluded.deleted,
          changed_at = excluded.changed_at
        WHERE media_item_revisions.revision < excluded.revision
        """,
        ids
      )
    end

    :ok
  end
end
