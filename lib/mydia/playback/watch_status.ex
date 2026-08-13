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

  alias Mydia.Media.Episode
  alias Mydia.Playback.Progress

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
end
