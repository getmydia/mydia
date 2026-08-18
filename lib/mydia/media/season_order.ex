defmodule Mydia.Media.SeasonOrder do
  @moduledoc """
  TVDB season orderings and the remap between them.

  TVDB returns several orderings of the same series in one response. Mydia
  historically kept only the official one, which puts all 170 episodes of a
  show like Black Clover in a single season. The other orderings regroup the
  same episode records rather than describing different ones, which is what
  makes switching between them lossless.
  """

  import Ecto.Query

  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Provider.Relay
  alias Mydia.Repo

  @values [:official, :dvd, :absolute]

  # Season numbers are validated non-negative and no real series approaches
  # 1000 seasons, so parking rows here cannot collide with live data. What
  # actually carries the correctness is that one statement parks every row in
  # the set at once: the parked coordinates stay unique because the originals
  # were, and no unparked row of that set remains to collide with.
  #
  # It also bounds the target range this function accepts. A mapping asking for
  # a season >= @offset would collide with the parked rows, and `conflicting?/2`
  # compares final coordinates only, so it cannot see that. The consequence is a
  # rolled-back transaction and an adapter-specific exception, not corruption.
  @offset 1000

  @spec values() :: [atom()]
  def values, do: @values

  @doc """
  Maps an ordering to the `type.type` string TVDB uses in its season records.
  """
  @spec tvdb_type(atom() | nil) :: String.t()
  def tvdb_type(nil), do: "official"
  def tvdb_type(order) when order in @values, do: Atom.to_string(order)

  @doc """
  A short, human label for an ordering, for UI display.
  """
  @spec label(atom() | nil) :: String.t()
  def label(nil), do: "Aired order"
  def label(:official), do: "Aired order"
  def label(:dvd), do: "DVD order"
  def label(:absolute), do: "Absolute order"

  @doc """
  The ordering a show is actually using right now: its recorded
  `season_order`, or `:official` when it has never been asked (a fresh
  import, or one nobody has touched) — matching `tvdb_type/1`'s default.
  """
  @spec effective(MediaItem.t()) :: atom()
  def effective(%MediaItem{season_order: nil}), do: :official
  def effective(%MediaItem{season_order: order}), do: order

  @doc """
  Looks up TVDB's alternative ("dvd") ordering for a show and, if it exists,
  the real per-season episode counts (specials excluded) — the numbers a
  suggestion banner needs to name the alternative concretely rather than
  offering an abstract choice.

  Returns `{:error, :no_alternative_ordering}` when the show has no TVDB
  "dvd" ordering to offer.
  """
  @spec suggest_alternative(MediaItem.t(), map()) ::
          {:ok, [pos_integer()]} | {:error, :missing_tvdb_id | :no_alternative_ordering | term()}
  def suggest_alternative(%MediaItem{tvdb_id: nil}, _config), do: {:error, :missing_tvdb_id}

  def suggest_alternative(%MediaItem{} = media_item, config) do
    provider_id = to_string(media_item.tvdb_id)

    with {:ok, raw_seasons} <- Relay.fetch_raw_seasons(config, provider_id),
         orderings = Relay.available_orderings(raw_seasons),
         true <- Map.has_key?(orderings, "dvd") do
      fetch_alternative_counts(config, provider_id, raw_seasons)
    else
      false -> {:error, :no_alternative_ordering}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_alternative_counts(config, provider_id, raw_seasons) do
    case Relay.fetch_ordering_episodes(config, provider_id, "dvd", raw_seasons) do
      {:ok, episodes} ->
        counts =
          episodes
          |> Enum.reject(&(&1.season_number == 0))
          |> Enum.group_by(& &1.season_number)
          |> Enum.sort_by(fn {season_number, _} -> season_number end)
          |> Enum.map(fn {_season_number, eps} -> length(eps) end)

        if counts == [] do
          {:error, :no_alternative_ordering}
        else
          {:ok, counts}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches every episode of `target`'s TVDB ordering and remaps the show onto
  it via `remap/3`.

  This is the counterpart to `suggest_alternative/2`: given a chosen
  ordering (from the banner, or a manual pick), it does the same kind of
  fetch and builds the `provider_episode_id => {season, episode}` mapping
  `remap/3` needs.

  Short-circuits to `{:ok, :confirmed}` — no fetch, no remap — when `target`
  is already the show's `effective/1` ordering. "The user was asked and
  chose what they already have" is a bookkeeping write, not a data move: it
  must succeed even for a show with no TVDB id, no reachable relay, or
  episodes with no provider id (all of which would otherwise refuse via
  `remap/3`'s own guards), because those are exactly the shows the banner
  exists for — the ones where the aired-order confirmation option can't be
  allowed to depend on the network working.

  When it isn't a no-op, refuses (without writing anything) if the fetched
  ordering does not account for every one of the show's episodes —
  `{:error, {:incomplete_ordering, missing_count}}`. TVDB sometimes lists an
  ordering that only covers part of a series; remapping just the covered
  subset would silently strand the rest at their old numbers under a
  `season_order` that claims otherwise, which is the "half-remapped show"
  `remap/3`'s docs already warn is worse than declining.
  """
  @spec switch(MediaItem.t(), atom(), map()) ::
          {:ok, non_neg_integer()}
          | {:ok, :confirmed}
          | {:error,
             :missing_tvdb_id
             | :no_alternative_ordering
             | :missing_provider_ids
             | :conflicting_mapping
             | {:incomplete_ordering, pos_integer()}
             | term()}
  def switch(%MediaItem{} = media_item, target, config) when target in @values do
    if target == effective(media_item) do
      confirm_current(media_item, target)
    else
      do_switch(media_item, target, config)
    end
  end

  defp confirm_current(%MediaItem{id: id}, target) do
    Repo.update_all(from(m in MediaItem, where: m.id == ^id), set: [season_order: target])
    {:ok, :confirmed}
  end

  defp do_switch(%MediaItem{tvdb_id: nil}, _target, _config), do: {:error, :missing_tvdb_id}

  defp do_switch(%MediaItem{} = media_item, target, config) do
    provider_id = to_string(media_item.tvdb_id)

    with {:ok, raw_seasons} <- Relay.fetch_raw_seasons(config, provider_id),
         {:ok, episodes} <-
           Relay.fetch_ordering_episodes(config, provider_id, tvdb_type(target), raw_seasons) do
      case episodes do
        [] ->
          {:error, :no_alternative_ordering}

        episodes ->
          mapping =
            episodes
            |> Enum.filter(& &1.provider_episode_id)
            |> Map.new(&{&1.provider_episode_id, {&1.season_number, &1.episode_number}})

          case missing_from_mapping(media_item, mapping) do
            [] -> remap(media_item, target, mapping)
            missing -> {:error, {:incomplete_ordering, length(missing)}}
          end
      end
    end
  end

  # Local episodes with a provider id that the fetched ordering never
  # mentioned. Episodes with no provider id at all are excluded here on
  # purpose — that is `remap/3`'s own `:missing_provider_ids` refusal to
  # raise, not this one's, and counting them here would misreport a
  # provider-id problem as an incomplete-ordering problem.
  defp missing_from_mapping(%MediaItem{id: id}, mapping) do
    Episode
    |> where([e], e.media_item_id == ^id)
    |> select([e], e.provider_episode_id)
    |> Repo.all()
    |> Enum.reject(&(is_nil(&1) or Map.has_key?(mapping, &1)))
  end

  @doc """
  Rewrites a show's season and episode numbers to a different ordering.

  `mapping` is `provider_episode_id => {season_number, episode_number}` for the
  target ordering. Nothing is inserted or deleted, so media file links, watch
  history, downloads and per-episode monitored flags all survive. Returns the
  number of episodes the mapping accounted for.

  Episodes the mapping does not mention keep the coordinates they already had.

  Both refusals happen before the first write, because a half-remapped show is
  worse than one that declines to move: the damage is silent and the user
  cannot tell which episodes shifted.

    * `{:error, :missing_provider_ids}` - some episode has no provider id, so
      there is no stable identity to remap it by.
    * `{:error, :conflicting_mapping}` - two episodes would land on the same
      `{season_number, episode_number}`, which the unique index forbids.
  """
  @spec remap(MediaItem.t(), atom(), %{String.t() => {integer(), integer()}}) ::
          {:ok, non_neg_integer()} | {:error, :missing_provider_ids | :conflicting_mapping}
  def remap(%MediaItem{id: id}, target, mapping) when target in @values and is_map(mapping) do
    episodes = Repo.all(from(e in Episode, where: e.media_item_id == ^id))

    cond do
      Enum.any?(episodes, &is_nil(&1.provider_episode_id)) ->
        {:error, :missing_provider_ids}

      conflicting?(episodes, mapping) ->
        {:error, :conflicting_mapping}

      true ->
        Repo.transaction(fn -> write_ordering(id, episodes, target, mapping) end)
    end
  end

  defp conflicting?(episodes, mapping) do
    coordinates = Enum.map(episodes, &target_coordinates(&1, mapping))

    length(Enum.uniq(coordinates)) != length(coordinates)
  end

  defp target_coordinates(%Episode{} = episode, mapping) do
    Map.get(
      mapping,
      episode.provider_episode_id,
      {episode.season_number, episode.episode_number}
    )
  end

  defp write_ordering(id, episodes, target, mapping) do
    # Pass one: park the rows we read out of the way. The unique index on
    # (media_item_id, season_number, episode_number) is not deferrable on
    # SQLite, so a single-pass update trips it the moment the target numbering
    # overlaps the current one — swapping two episodes is enough.
    #
    # Scoped to the ids we actually read, not to the whole show. An episode
    # inserted between the read above and this transaction is absent from
    # `episodes`, so pass two would never restore it: a blanket park would
    # leave it sitting at season 1001 after a clean commit, which is precisely
    # the silent damage the refusals above exist to prevent. Leaving it
    # unparked instead means a mapped write onto its slot raises and rolls the
    # whole transaction back — loud, and recoverable by retrying.
    episode_ids = Enum.map(episodes, & &1.id)

    Repo.update_all(
      from(e in Episode, where: e.id in ^episode_ids),
      inc: [season_number: @offset]
    )

    # Pass two: write final values. Mapped rows first so that the rows the
    # target ordering actually describes claim their slots before anything is
    # restored into the space around them.
    {mapped, unmapped} =
      Enum.split_with(episodes, &Map.has_key?(mapping, &1.provider_episode_id))

    Enum.each(mapped, fn episode ->
      {season_number, episode_number} = Map.fetch!(mapping, episode.provider_episode_id)
      move(episode, season_number, episode_number)
    end)

    # Not in the target ordering. Restore the original numbering rather than
    # leaving the row parked at +1000, where nothing in the UI would show it.
    Enum.each(unmapped, &move(&1, &1.season_number, &1.episode_number))

    Repo.update_all(from(m in MediaItem, where: m.id == ^id), set: [season_order: target])

    length(mapped)
  end

  defp move(%Episode{id: id}, season_number, episode_number) do
    Repo.update_all(
      from(e in Episode, where: e.id == ^id),
      set: [season_number: season_number, episode_number: episode_number]
    )
  end
end
