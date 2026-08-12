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

  @doc """
  Returns the next episode to play and why.

  - `{:continue, episode}` an episode is partially watched
  - `{:next, episode}` the first unwatched episode, with history present
  - `{:start, episode}` the first episode, with no history at all
  - `:all_watched` nothing is left
  """
  def determine(episodes, progress_map) do
    in_progress_episode =
      Enum.find(episodes, fn episode ->
        case Map.get(progress_map, episode.id) do
          %Progress{watched: false, completion_percentage: pct} when pct < @watched_threshold ->
            true

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
