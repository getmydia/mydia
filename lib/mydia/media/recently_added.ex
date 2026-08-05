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

  @doc """
  Maps media item id to the time its newest content arrived.

  Items with no files are absent rather than nil, so a caller can distinguish
  "nothing yet" with `Map.get/2` and its own default.

  Options:

    * `:ids` - restrict to these media item ids. An empty list returns `%{}`
      without hitting the database.
  """
  @spec added_at_map(keyword()) :: %{binary() => DateTime.t()}
  def added_at_map(opts \\ [])

  def added_at_map(opts) do
    case Keyword.fetch(opts, :ids) do
      {:ok, []} ->
        %{}

      {:ok, ids} ->
        ids |> item_timestamps_query() |> Repo.all() |> Map.new()

      :error ->
        nil |> item_timestamps_query() |> Repo.all() |> Map.new()
    end
  end

  # One row per (owning item, episode) slot, carrying the slot's earliest file.
  # Public to this module only; Task 3 reuses it for windowed counts.
  @doc false
  @spec slots_query() :: Ecto.Query.t()
  def slots_query do
    from f in MediaFile,
      left_join: e in Episode,
      on: f.episode_id == e.id,
      where: not is_nil(e.media_item_id) or not is_nil(f.media_item_id),
      group_by: [coalesce(e.media_item_id, f.media_item_id), f.episode_id],
      select: %{
        media_item_id: coalesce(e.media_item_id, f.media_item_id),
        episode_id: f.episode_id,
        first_added_at: type(min(f.inserted_at), :utc_datetime)
      }
  end

  defp item_timestamps_query(ids) do
    slots = slots_query()

    query =
      from s in subquery(slots),
        group_by: s.media_item_id,
        select: {s.media_item_id, type(max(s.first_added_at), :utc_datetime)}

    if is_nil(ids) do
      query
    else
      where(query, [s], s.media_item_id in ^ids)
    end
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

  # The newest slot per item, resolved to an episode. Slots whose episode_id is
  # NULL (unmatched files) contribute a timestamp but no episode to name.
  defp load_latest_episodes([]), do: %{}

  defp load_latest_episodes(rows) do
    ids = Enum.map(rows, & &1.media_item_id)

    slots = slots_query()

    # `subquery/1` returns an %Ecto.SubQuery{}, not a query, so it cannot be
    # piped into `where/3`. It has to be the source of a `from`.
    newest_episode_ids =
      from(s in subquery(slots),
        where: s.media_item_id in ^ids and not is_nil(s.episode_id)
      )
      |> Repo.all()
      |> Enum.group_by(& &1.media_item_id)
      |> Map.new(fn {item_id, slots} ->
        {item_id, Enum.max_by(slots, & &1.first_added_at, DateTime).episode_id}
      end)

    episodes =
      Episode
      |> where([e], e.id in ^Map.values(newest_episode_ids))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Map.new(newest_episode_ids, fn {item_id, episode_id} ->
      {item_id, Map.get(episodes, episode_id)}
    end)
  end

  # `sum/1` returns a plain integer on SQLite but a `Decimal` on PostgreSQL.
  # Normalize here so callers always see an integer, regardless of adapter.
  defp to_integer(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_integer(count) when is_integer(count), do: count
end
