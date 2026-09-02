defmodule Mydia.Playback.NextEpisode do
  @moduledoc """
  The in-memory decision for "which episode of this show comes next".

  Extracted so the single-show path (`Playback.get_next_episode/2`, which loads
  one show) and the batched On Deck path (which loads many shows at once) run
  the same logic instead of two copies that can drift apart.

  Callers are responsible for passing `episodes` already ordered by season then
  episode number, and already filtered to episodes with an untrashed file.
  """

  alias Mydia.Playback.Progress

  @watched_threshold 90.0
  @default_min_position_seconds 120

  @doc """
  Returns the next episode to play and why.

  - `{:continue, episode}` an episode is partially watched
  - `{:next, episode}` the first unwatched episode, with history present
  - `{:start, episode}` the first episode, with no history at all
  - `:all_watched` nothing is left

  ## Options

    * `:min_position_seconds` - how far into an episode counts as a resume
      point (default #{@default_min_position_seconds})

  A resume point outranks the unwatched frontier: half an episode of season
  three beats an untouched season one, because that is where the viewer
  actually is. That only holds for a position someone could have reached by
  watching. A few seconds on the clock is what a mis-click, a preview, or a
  glance at the wrong title leaves behind, and treating one as a resume point
  pins the card to an episode the viewer never started while the episode they
  are really on sits unwatched behind it.

  So a row under the floor is not a resume point. The episode still shows up
  as the first unwatched one when the frontier is where it sits, and the row
  itself survives, so the seconds are still there to resume from once the
  viewer chooses to play it.

  The floor matches On Deck's own definition of real viewing, which already
  refuses to put a show on the rail on the strength of a row like this. Before
  this, a show could reach the rail on one episode's history and then name a
  different episode the same rule had just called noise.
  """
  def determine(episodes, progress_map, opts \\ []) do
    min_position = Keyword.get(opts, :min_position_seconds, @default_min_position_seconds)

    in_progress_episode =
      Enum.find(episodes, fn episode ->
        case Map.get(progress_map, episode.id) do
          %Progress{watched: false, completion_percentage: pct} = progress
          when pct < @watched_threshold ->
            (progress.position_seconds || 0) >= min_position

          _ ->
            false
        end
      end)

    if in_progress_episode do
      {:continue, in_progress_episode}
    else
      unwatched_episode =
        Enum.find(episodes, fn episode ->
          case Map.get(progress_map, episode.id) do
            nil -> true
            %Progress{watched: false} -> true
            _ -> false
          end
        end)

      case unwatched_episode do
        nil ->
          :all_watched

        episode ->
          if progress_map == %{} do
            {:start, episode}
          else
            {:next, episode}
          end
      end
    end
  end
end
