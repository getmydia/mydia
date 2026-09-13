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
  why the API sources `MediaItem.updatedAt` from it through the `live_changed_at*`
  reads. Those read markers tombstones included, so an item deleted between a
  hydration and its marker read is absent rather than a crash. Nothing here
  orders by a wall clock.
  """

  require Logger

  import Ecto.Query

  alias Mydia.DB
  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.Repo

  @typedoc "The state of one item's marker, tombstones included."
  @type marker :: %{changed_at: DateTime.t(), deleted: boolean()}

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
  Every marker for the given ids, tombstones included, in one query.

  A caller that hydrated its items in one query uses this so it can tell a
  concurrent delete (a tombstone) from a wholly absent marker without a second
  query per row. An id with no marker at all is absent from the map.
  """
  @spec markers_by_ids([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => marker()}
  def markers_by_ids([]), do: %{}

  def markers_by_ids(ids) do
    MediaItemRevision
    |> where([r], r.media_item_id in ^ids)
    |> select([r], {r.media_item_id, r.changed_at, r.deleted})
    |> Repo.all()
    |> Map.new(fn {id, changed_at, deleted} ->
      {id, %{changed_at: changed_at, deleted: deleted}}
    end)
  end

  @doc """
  The `changed_at` for each of `ids`, with tombstones resolved to nil.

  One query for the whole set. A tombstone means the item was deleted
  concurrently, which is ordinary absence and reads as nil, exactly as an item
  that was missing from the hydration. An id with no marker row at all is the
  internal invariant violation the design spec names: it is logged and answered
  `{:error, message}` rather than fabricated into a timestamp.
  """
  @spec live_changed_at_by_ids([Ecto.UUID.t()]) ::
          {:ok, %{Ecto.UUID.t() => DateTime.t() | nil}} | {:error, String.t()}
  def live_changed_at_by_ids(ids) do
    ids = Enum.uniq(ids)
    markers = markers_by_ids(ids)

    case Enum.find(ids, &(not Map.has_key?(markers, &1))) do
      nil -> {:ok, Map.new(ids, &{&1, marker_changed_at(Map.fetch!(markers, &1))})}
      missing -> {:error, invariant_violation(missing)}
    end
  end

  @doc """
  The live `changed_at` of one media item's marker.

  A tombstone resolves to nil: the item was deleted concurrently, which is
  ordinary absence. An id with no marker at all is the internal invariant
  violation the design spec names, so it is logged and answered
  `{:error, message}`.
  """
  @spec live_changed_at(Ecto.UUID.t()) :: {:ok, DateTime.t() | nil} | {:error, String.t()}
  def live_changed_at(media_item_id) do
    case Repo.get_by(MediaItemRevision, media_item_id: media_item_id) do
      nil -> {:error, invariant_violation(media_item_id)}
      marker -> {:ok, marker_changed_at(marker)}
    end
  end

  @doc """
  The live `changed_at` of one media item's marker for a payload read.

  Like `live_changed_at/1`, except a wholly absent marker keeps the invariant
  error `changed_at!/1` raises.
  """
  @spec live_changed_at!(Ecto.UUID.t()) :: DateTime.t() | nil
  def live_changed_at!(media_item_id) do
    MediaItemRevision
    |> Repo.get_by!(media_item_id: media_item_id)
    |> marker_changed_at()
  end

  defp marker_changed_at(%{deleted: true}), do: nil
  defp marker_changed_at(%{changed_at: changed_at}), do: changed_at

  defp invariant_violation(media_item_id) do
    Logger.error("Library API revision feed: #{media_item_id} has no revision marker")

    "Library API internal invariant violation: media item #{media_item_id} " <>
      "has a row but no revision marker"
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
