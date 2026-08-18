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
  alias Mydia.Repo

  @values [:official, :dvd, :absolute]

  # Season numbers are validated non-negative and no real series approaches
  # 1000 seasons, so parking rows here cannot collide with live data.
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
    # Pass one: park every row out of the way. The unique index on
    # (media_item_id, season_number, episode_number) is not deferrable on
    # SQLite, so a single-pass update trips it the moment the target numbering
    # overlaps the current one — swapping two episodes is enough.
    Repo.update_all(
      from(e in Episode, where: e.media_item_id == ^id),
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
