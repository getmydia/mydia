defmodule Mydia.Playback.WatchStatus do
  @moduledoc """
  The browse-surface rollup of watch state.

  `Mydia.Playback.Progress` is the per-user playback row used to resume a
  movie or an episode. It cannot describe a show or a season, because neither
  has a row of its own. This struct is the projection the browse surfaces
  actually render, and it covers all four.

  The counting rule lives here and only here. An episode counts as unwatched
  when it has at least one non-trashed file, its season number is not 0, and
  it has either no progress row or a row whose `watched` flag is not true.
  That last clause is the same predicate
  `Mydia.Playback.NextEpisode.determine/2` uses to pick the next episode, so
  a badge count and a next-up selection cannot disagree with each other.
  """

  import Ecto.Query

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Playback.Progress
  alias Mydia.Repo

  defstruct [:watched, :percentage, :unwatched_episode_count]

  @type t :: %__MODULE__{
          watched: boolean(),
          percentage: float() | nil,
          unwatched_episode_count: non_neg_integer() | nil
        }

  @doc """
  Rolls a single movie's or episode's progress row up into a status.

  `unwatched_episode_count` is nil, which is what tells the client this is a
  leaf rather than a container.
  """
  @spec from_progress(Progress.t() | nil) :: t()
  def from_progress(nil) do
    %__MODULE__{watched: false, percentage: nil, unwatched_episode_count: nil}
  end

  def from_progress(%Progress{} = progress) do
    %__MODULE__{
      watched: progress.watched || false,
      percentage: progress.completion_percentage,
      unwatched_episode_count: nil
    }
  end

  @doc """
  Rolls a show's or a season's episodes up into a status.

  `episode_ids_with_files` is a `MapSet` of episode ids holding at least one
  non-trashed file. `progress_by_episode_id` maps an episode id to its
  `Progress` row; absent keys mean the user has never played that episode.

  `percentage` is nil, because a container has no resume point.
  """
  @spec from_episodes([Episode.t()], MapSet.t(), %{term() => Progress.t()}) :: t()
  def from_episodes(episodes, episode_ids_with_files, progress_by_episode_id) do
    countable =
      Enum.filter(episodes, fn episode ->
        episode.season_number != 0 and MapSet.member?(episode_ids_with_files, episode.id)
      end)

    unwatched_count =
      Enum.count(countable, fn episode ->
        case Map.get(progress_by_episode_id, episode.id) do
          nil -> true
          %Progress{watched: watched} -> watched != true
        end
      end)

    %__MODULE__{
      # A show with nothing playable is not "watched", it is empty. Reporting
      # true here would draw a finished badge on a show the user has never
      # been able to start.
      watched: countable != [] and unwatched_count == 0,
      percentage: nil,
      unwatched_episode_count: unwatched_count
    }
  end

  @doc """
  Loads everything the watch rollups need for a set of shows, in a fixed
  number of queries.

  Shaped for `Absinthe.Resolution.Helpers.batch/3`: the extra context comes
  first, the collected keys second, and the return is keyed by those keys.

  Three queries, regardless of how many shows are on screen. Resolving this
  per show is what made `season_count` and `episode_count` an N+1 in the first
  place, and a 50-show library grid was issuing about 100 episode queries
  before this existed.

  `user_id` may be nil, in which case no progress is applied and every
  playable episode counts as unwatched. The counts stay correct for the
  unauthenticated caller that still asks for `season_count`.
  """
  @spec load_shows(term() | nil, [term()]) :: %{term() => map()}
  def load_shows(user_id, show_ids) do
    show_ids = Enum.uniq(show_ids)

    episodes =
      Episode
      |> where([e], e.media_item_id in ^show_ids)
      |> order_by([e], asc: e.season_number, asc: e.episode_number)
      |> Repo.all()

    episode_ids = Enum.map(episodes, & &1.id)

    # Gate on `episode_id`, never on `media_item_id`.
    #
    # A TV media_file carries a NULL `media_item_id`; only the episode link is
    # populated. Filtering these rows by `media_item_id` silently returns
    # nothing for every show, which makes every episode look file-less and
    # every badge read 0. That exact mistake has shipped twice in this
    # codebase, and it fails silently rather than raising.
    #
    # `is_nil(trashed_at)` mirrors the default in
    # `Mydia.Library.list_media_files/1`, which is what `resolve_has_file/3`
    # goes through. Without it a trashed file would keep an episode countable
    # here while `hasFile` reported false on the same screen.
    file_ids =
      MediaFile
      |> where([f], f.episode_id in ^episode_ids and is_nil(f.trashed_at))
      |> select([f], f.episode_id)
      |> distinct(true)
      |> Repo.all()
      |> MapSet.new()

    progress = load_progress(user_id, episode_ids)
    episodes_by_show = Enum.group_by(episodes, & &1.media_item_id)

    Map.new(show_ids, fn show_id ->
      {show_id,
       %{
         episodes: Map.get(episodes_by_show, show_id, []),
         file_ids: file_ids,
         progress: progress
       }}
    end)
  end

  defp load_progress(nil, _episode_ids), do: %{}

  defp load_progress(user_id, episode_ids) do
    Progress
    |> where([p], p.user_id == ^user_id and p.episode_id in ^episode_ids)
    |> Repo.all()
    |> Map.new(&{&1.episode_id, &1})
  end

  @doc "Every episode in a bundle, in season and episode order."
  @spec episodes(map() | nil) :: [Episode.t()]
  def episodes(nil), do: []
  def episodes(bundle), do: bundle.episodes

  @doc "Rolls a whole show up from its bundle."
  @spec for_show(map() | nil) :: t()
  def for_show(nil), do: from_episodes([], MapSet.new(), %{})

  def for_show(bundle) do
    from_episodes(bundle.episodes, bundle.file_ids, bundle.progress)
  end

  @doc "Rolls a single season up from its show's bundle."
  @spec for_season(map() | nil, integer()) :: t()
  def for_season(nil, _season_number), do: from_episodes([], MapSet.new(), %{})

  def for_season(bundle, season_number) do
    bundle.episodes
    |> Enum.filter(&(&1.season_number == season_number))
    |> from_episodes(bundle.file_ids, bundle.progress)
  end
end
