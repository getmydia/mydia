defmodule Mydia.Media.RecentlyAdded do
  @moduledoc """
  Derives when an item's *content* arrived, as opposed to when its record was
  created.

  `media_items.inserted_at` answers "when did I start tracking this", which for
  a long-running show is years before its newest episode. This module answers
  "when did I last get something new to watch".

  ## Slots

  Files are grouped into slots: one per episode of a show, one per movie. A
  slot's timestamp is the *earliest* file in it, counting trashed rows. A
  quality upgrade inserts a later row into a slot that already has an earlier
  one, so it cannot move the timestamp. An item's timestamp is the newest of
  its slots.

  ## Linking

  The two file kinds are linked to their item differently. A movie's file sets
  `media_item_id` and leaves `episode_id` NULL. An episode's file is the
  mirror image: `MetadataEnricher` stamps `episode_id` and `media_item_id`
  stays NULL. Grouping on `media_files.media_item_id` alone therefore yields
  nothing at all for TV shows, so the owning item is
  `coalesce(episodes.media_item_id, media_files.media_item_id)` over a left
  join.
  """

  import Ecto.Query

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Media.RecentlyAdded.Entry
  alias Mydia.Repo

  # Keeps a single `:ids` query under both SQLite's 32,766 and PostgreSQL's
  # 65,535 bind-parameter ceilings with plenty of headroom, regardless of how
  # many other parameters the same query carries.
  @id_chunk_size 500

  @doc """
  Maps media item id to the time its newest content arrived.

  Items with no files are absent rather than nil, so a caller can distinguish
  "nothing yet" with `Map.get/2` and its own default.

  Options:

    * `:ids` - restrict to these media item ids. An empty list returns `%{}`
      without hitting the database. A larger list is chunked into batches of
      #{@id_chunk_size} and queried separately, with the per-chunk maps
      merged, so a caller scoping to an entire library (a sort on the media
      library page, or an unwatched/favorites rail) can never build a single
      query past a bind-parameter ceiling. Chunking is chosen over dropping
      the filter on a large list because the filter is what keeps the query
      cheap: an unfiltered aggregate re-scans and re-groups every media file
      in the library, which is exactly the cost this option exists to avoid.
  """
  @spec added_at_map(keyword()) :: %{binary() => DateTime.t()}
  def added_at_map(opts \\ [])

  def added_at_map(opts) do
    case Keyword.fetch(opts, :ids) do
      {:ok, []} ->
        %{}

      {:ok, ids} ->
        ids
        |> Enum.chunk_every(@id_chunk_size)
        |> Enum.reduce(%{}, fn chunk, acc ->
          Map.merge(acc, chunk |> item_timestamps_query() |> Repo.all() |> Map.new())
        end)

      :error ->
        nil |> item_timestamps_query() |> Repo.all() |> Map.new()
    end
  end

  # One row per (owning item, episode) slot, carrying the slot's earliest file.
  # Public to this module only.
  #
  # `ids`, when given, filters slots to those whose owning item is in the
  # list. The filter is a `where` on the media_files/episodes join, applied
  # *before* `group_by`, rather than a filter on the outer aggregate: a caller
  # that only needs a handful of items (added_at_map/1's per-chunk scoping,
  # load_latest_episodes/1's lookup for the rail) never pays for grouping the
  # whole table first and discarding most of the result.
  @doc false
  @spec slots_query([binary()] | nil) :: Ecto.Query.t()
  def slots_query(ids \\ nil) do
    from f in MediaFile,
      left_join: e in Episode,
      on: f.episode_id == e.id,
      where: not is_nil(e.media_item_id) or not is_nil(f.media_item_id),
      where: ^id_filter(ids),
      group_by: [coalesce(e.media_item_id, f.media_item_id), f.episode_id],
      select: %{
        media_item_id: coalesce(e.media_item_id, f.media_item_id),
        episode_id: f.episode_id,
        first_added_at: type(min(f.inserted_at), :utc_datetime)
      }
  end

  defp id_filter(nil), do: dynamic([f, e], true)

  defp id_filter(ids) do
    # `coalesce(...) in ^ids` alone leaves Postgrex to guess the comparison's
    # type from a bare `coalesce/2` expression, which it cannot: it falls back
    # to `:binary` and then rejects every UUID string with an "expected a
    # binary of 16 bytes" encode error. Typing the *left* side as `:binary_id`
    # (the type `media_item_id` already has on both `f` and `e`) lets Ecto
    # infer the correct encoding for `^ids` from it, on both adapters — SQLite
    # never needed this (it has no binary UUID representation to get wrong),
    # but tagging the RHS list directly with `{:array, :binary_id}` instead
    # breaks *SQLite's* plain `IN (?, ?, ...)` expansion, so the type belongs
    # on the expression being compared, not the list.
    dynamic(
      [f, e],
      type(coalesce(e.media_item_id, f.media_item_id), :binary_id) in ^ids
    )
  end

  defp item_timestamps_query(ids) do
    from s in subquery(slots_query(ids)),
      group_by: s.media_item_id,
      select: {s.media_item_id, type(max(s.first_added_at), :utc_datetime)}
  end

  @doc """
  Lists items whose content arrived on or after `:since`, newest first.

  Options:

    * `:since` - required `DateTime` cutoff.
    * `:types` - restrict to these `media_items.type` values.
    * `:limit` - cap the number of entries.

  Items with no files never appear, since they have no slots.
  """
  @spec list_recent(keyword()) :: [Entry.t()]
  def list_recent(opts) do
    since = Keyword.fetch!(opts, :since)

    rows =
      since
      |> windowed_rows_query(Keyword.get(opts, :types))
      |> Repo.all()

    rows =
      case Keyword.get(opts, :limit) do
        nil -> rows
        limit -> Enum.take(rows, limit)
      end

    items = load_items(Enum.map(rows, & &1.media_item_id))
    latest = load_latest_episodes(rows)

    Enum.flat_map(rows, fn row ->
      case Map.fetch(items, row.media_item_id) do
        # An item deleted between the aggregate and the load.
        :error ->
          []

        {:ok, item} ->
          show? = item.type == "tv_show"

          [
            %Entry{
              media_item: item,
              content_added_at: row.content_added_at,
              new_episode_count: if(show?, do: to_integer(row.new_episode_count)),
              latest_episode: if(show?, do: Map.get(latest, row.media_item_id))
            }
          ]
      end
    end)
  end

  defp windowed_rows_query(since, types) do
    slots = slots_query()

    query =
      from s in subquery(slots),
        group_by: s.media_item_id,
        having: type(max(s.first_added_at), :utc_datetime) >= ^since,
        order_by: [desc: type(max(s.first_added_at), :utc_datetime)],
        select: %{
          media_item_id: s.media_item_id,
          content_added_at: type(max(s.first_added_at), :utc_datetime),
          new_episode_count:
            sum(fragment("CASE WHEN ? >= ? THEN 1 ELSE 0 END", s.first_added_at, ^since))
        }

    case types do
      nil ->
        query

      [] ->
        query

      types ->
        item_ids = from(m in MediaItem, where: m.type in ^types, select: m.id)
        where(query, [s], s.media_item_id in subquery(item_ids))
    end
  end

  defp load_items([]), do: %{}

  defp load_items(ids) do
    MediaItem
    |> where([m], m.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # The newest slot per item, resolved to an episode. The max must be taken
  # over ALL of an item's slots, not just the matched ones — filtering out
  # unmatched slots before the max would name an older matched episode for an
  # item whose newest arrival was actually an unmatched file. Slots whose
  # episode_id is NULL (unmatched files) contribute a timestamp but no episode
  # to name.
  defp load_latest_episodes([]), do: %{}

  defp load_latest_episodes(rows) do
    ids = Enum.map(rows, & &1.media_item_id)

    # Filtering inside slots_query/1 means this scan-and-group only ever
    # touches the handful of items the caller already resolved (the rail's
    # page, after list_recent/1's :limit), rather than repeating the full
    # unfiltered aggregate windowed_rows_query/2 already ran.
    newest_episode_ids =
      ids
      |> slots_query()
      |> Repo.all()
      |> Enum.group_by(& &1.media_item_id)
      |> Map.new(fn {item_id, item_slots} ->
        newest = Enum.max_by(item_slots, & &1.first_added_at, DateTime)
        {item_id, newest.episode_id}
      end)

    episode_ids = newest_episode_ids |> Map.values() |> Enum.reject(&is_nil/1)

    episodes =
      Episode
      |> where([e], e.id in ^episode_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Map.new(newest_episode_ids, fn {item_id, episode_id} ->
      {item_id, episode_id && Map.get(episodes, episode_id)}
    end)
  end

  # `sum/1` returns a plain integer on SQLite but a `Decimal` on PostgreSQL.
  # Normalize here so callers always see an integer, regardless of adapter.
  defp to_integer(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_integer(count) when is_integer(count), do: count
end
