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
end
