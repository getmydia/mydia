defmodule Mydia.Media.Episodes do
  @moduledoc """
  Episode reads and writes for TV shows: listing, lookup, navigation and CRUD.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{Episode, Restrictions}

  @doc """
  Returns the list of episodes for a media item.

  ## Options
    - `:season` - Filter by season number
    - `:monitored` - Filter by monitored status (true/false)
    - `:preload` - List of associations to preload
  """
  @spec list_episodes(Scope.t(), binary(), keyword()) :: [Episode.t()]
  def list_episodes(%Scope{} = scope, media_item_id, opts \\ []) do
    Episode
    |> Restrictions.apply_to_episodes(scope)
    |> where([e], e.media_item_id == ^media_item_id)
    |> apply_episode_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([e], asc: e.season_number, asc: e.episode_number)
    |> Repo.all()
  end

  @doc """
  How many episodes a season pack for `season_number` can be expected to hold:
  the episodes that have aired, or every episode in the season when none have
  aired or none carry an air date. Never below 1, so it is always safe to
  divide by.

  Used to size a season pack per episode when ranking it; see the
  `:episode_count` option of `Mydia.Indexers.ReleaseRanker`. A sizing figure
  for a title the caller already holds, so it reads under `Scope.system/0`.
  """
  @spec season_pack_episode_count(binary(), integer()) :: pos_integer()
  def season_pack_episode_count(media_item_id, season_number) do
    episodes = list_episodes(Scope.system(), media_item_id, season: season_number)
    today = Date.utc_today()

    aired =
      Enum.count(episodes, fn episode ->
        episode.air_date != nil and Date.compare(episode.air_date, today) != :gt
      end)

    max(if(aired > 0, do: aired, else: length(episodes)), 1)
  end

  @doc """
  Gets a single episode.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the episode does not exist.
  """
  @spec get_episode!(Scope.t(), binary(), keyword()) :: Episode.t()
  def get_episode!(%Scope{} = scope, id, opts \\ []) do
    Episode
    |> Restrictions.apply_to_episodes(scope)
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single episode by media item ID, season, and episode number.
  """
  @spec get_episode_by_number(Scope.t(), binary(), integer(), integer(), keyword()) ::
          Episode.t() | nil
  def get_episode_by_number(
        %Scope{} = scope,
        media_item_id,
        season_number,
        episode_number,
        opts \\ []
      ) do
    Episode
    |> Restrictions.apply_to_episodes(scope)
    |> where([e], e.media_item_id == ^media_item_id)
    |> where([e], e.season_number == ^season_number)
    |> where([e], e.episode_number == ^episode_number)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  The highest regular-season and episode numbers recorded for a show.

  Season 0 (specials) is excluded from the aggregate. This function exists to
  bound plausible *regular-season* coordinates for `EpisodeMinter`, and
  specials routinely carry episode numbers far outside that range -- a
  special's episode number must never raise the ceiling used to judge a
  regular-season file.

  Returns `{0, 0}` for a show with no regular-season episodes so callers can
  treat the result as a numeric ceiling with no nil branch. `max/1` over an
  integer column behaves identically on SQLite and PostgreSQL.
  """
  @spec episode_bounds(binary()) :: {non_neg_integer(), non_neg_integer()}
  def episode_bounds(media_item_id) do
    {season, episode} =
      Episode
      |> where([e], e.media_item_id == ^media_item_id)
      |> where([e], e.season_number > 0)
      |> select([e], {max(e.season_number), max(e.episode_number)})
      |> Repo.one() || {nil, nil}

    {season || 0, episode || 0}
  end

  @doc """
  Every `{season_number, episode_number}` pair recorded for a show, specials
  included. Empty when the show has no episode rows yet.

  Lets the import matcher tell a file naming an episode the show has from one
  naming an episode it does not, without loading episode structs.
  """
  @spec episode_coordinates(binary()) :: MapSet.t({integer(), integer()})
  def episode_coordinates(media_item_id) do
    Episode
    |> where([e], e.media_item_id == ^media_item_id)
    |> select([e], {e.season_number, e.episode_number})
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Gets the next episode for the given episode.
  Returns the next episode in the same season if available,
  otherwise returns the first episode of the next season.
  Returns nil if there is no next episode.
  """
  @spec get_next_episode(Scope.t(), Episode.t(), keyword()) :: Episode.t() | nil
  def get_next_episode(%Scope{} = scope, %Episode{} = episode, opts \\ []) do
    # Try to get next episode in same season first
    next_in_season =
      Episode
      |> Restrictions.apply_to_episodes(scope)
      |> where([e], e.media_item_id == ^episode.media_item_id)
      |> where([e], e.season_number == ^episode.season_number)
      |> where([e], e.episode_number > ^episode.episode_number)
      |> order_by([e], asc: e.episode_number)
      |> limit(1)
      |> maybe_preload(opts[:preload])
      |> Repo.one()

    case next_in_season do
      nil ->
        # No more episodes in current season, try next season
        Episode
        |> Restrictions.apply_to_episodes(scope)
        |> where([e], e.media_item_id == ^episode.media_item_id)
        |> where([e], e.season_number > ^episode.season_number)
        |> order_by([e], asc: e.season_number, asc: e.episode_number)
        |> limit(1)
        |> maybe_preload(opts[:preload])
        |> Repo.one()

      episode ->
        episode
    end
  end

  @doc """
  Creates an episode.
  """
  @spec create_episode(map()) :: {:ok, Episode.t()} | {:error, Ecto.Changeset.t()}
  def create_episode(attrs \\ %{}) do
    %Episode{}
    |> Episode.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an episode.
  """
  @spec update_episode(Episode.t(), map()) :: {:ok, Episode.t()} | {:error, Ecto.Changeset.t()}
  def update_episode(%Episode{} = episode, attrs) do
    episode
    |> Episode.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an episode.
  """
  @spec delete_episode(Episode.t()) :: {:ok, Episode.t()} | {:error, Ecto.Changeset.t()}
  def delete_episode(%Episode{} = episode) do
    Repo.transaction(fn ->
      case Mydia.ImportCandidates.demote_episode_files(episode) do
        {:ok, :ok} ->
          case Repo.delete(episode) do
            {:ok, deleted} -> deleted
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking episode changes.
  """
  @spec change_episode(Episode.t(), map()) :: Ecto.Changeset.t()
  def change_episode(%Episode{} = episode, attrs \\ %{}) do
    Episode.changeset(episode, attrs)
  end

  defp apply_episode_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:season, season}, query ->
        where(query, [e], e.season_number == ^season)

      {:monitored, monitored}, query ->
        where(query, [e], e.monitored == ^monitored)

      _other, query ->
        query
    end)
  end
end
