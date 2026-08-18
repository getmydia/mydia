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
  """
  @spec switch(MediaItem.t(), atom(), map()) ::
          {:ok, non_neg_integer()}
          | {:error,
             :missing_tvdb_id
             | :no_alternative_ordering
             | :missing_provider_ids
             | :conflicting_mapping
             | term()}
  def switch(%MediaItem{tvdb_id: nil}, _target, _config), do: {:error, :missing_tvdb_id}

  def switch(%MediaItem{} = media_item, target, config) when target in @values do
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

          remap(media_item, target, mapping)
      end
    end
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
