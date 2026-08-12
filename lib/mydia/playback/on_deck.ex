defmodule Mydia.Playback.OnDeck do
  @moduledoc """
  Builds the Continue Watching rail: the things a user is genuinely in the
  middle of, most recent first.

  The rail merges two kinds of card that used to live on separate rows. A
  `:continue` entry is a resume point, a movie or episode left partway. A
  `:next` entry is the successor of an episode just finished, which has no
  progress row of its own and so could never appear on a resume-only rail.

  Membership hangs on one idea: a progress row only counts as real viewing if
  it is either marked watched or has at least two minutes on the clock, and it
  happened inside the last ninety days. The watched branch matters because
  media-server sync writes synthetic rows shaped `position 0 / duration 1`, and
  a seconds-only floor would read those as "never watched" and suppress the
  next-episode card for an entire synced library.

  The exact thresholds are the `@default_min_position_seconds` and
  `@default_max_age_days` attributes below, overridable per call.
  """

  import Ecto.Query

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Playback.{NextEpisode, OnDeckEntry, Progress}
  alias Mydia.Repo

  @default_min_position_seconds 120
  @default_max_age_days 90
  @default_limit 20
  @watched_threshold 90.0

  @doc """
  Returns the user's On Deck entries, most recently watched first.

  ## Options

    * `:limit` - how many entries to return (default #{@default_limit})
    * `:min_position_seconds` - the viewing floor (default #{@default_min_position_seconds})
    * `:max_age_days` - the recency window (default #{@default_max_age_days})
    * `:now` - the clock, injectable so tests need not manipulate real time
  """
  @spec list(binary(), keyword()) :: [OnDeckEntry.t()]
  def list(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    min_position = Keyword.get(opts, :min_position_seconds, @default_min_position_seconds)
    max_age_days = Keyword.get(opts, :max_age_days, @default_max_age_days)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -max_age_days, :day)

    counting =
      from(p in Progress, where: p.user_id == ^user_id)
      |> Repo.all()
      |> Enum.filter(&counting_row?(&1, min_position, cutoff))

    (movie_entries(counting) ++ show_entries(counting, user_id))
    |> Enum.sort_by(&sort_key/1, :desc)
    |> Enum.take(limit)
  end

  # Sorted on a tuple so entries sharing a timestamp, which a bulk watched
  # import makes common, still come back in a stable order across requests.
  defp sort_key(entry) do
    {DateTime.to_unix(entry.sort_at, :microsecond), OnDeckEntry.id(entry)}
  end

  defp counting_row?(%Progress{last_watched_at: nil}, _min_position, _cutoff), do: false

  defp counting_row?(%Progress{} = progress, min_position, cutoff) do
    real_viewing? =
      progress.watched == true or (progress.position_seconds || 0) >= min_position

    real_viewing? and DateTime.compare(progress.last_watched_at, cutoff) != :lt
  end

  defp movie_entries(counting) do
    candidates =
      Enum.filter(counting, fn progress ->
        not is_nil(progress.media_item_id) and progress.watched == false and
          (progress.completion_percentage || 0.0) < @watched_threshold
      end)

    ids = Enum.map(candidates, & &1.media_item_id)
    movies = ids |> load_media_items() |> Map.new(&{&1.id, &1})
    files = load_movie_files(ids)

    for progress <- candidates,
        movie = Map.get(movies, progress.media_item_id),
        not is_nil(movie),
        movie_files = Map.get(files, progress.media_item_id, []),
        movie_files != [] do
      %OnDeckEntry{
        kind: :movie,
        state: :continue,
        media_item: movie,
        progress: progress,
        files: movie_files,
        sort_at: progress.last_watched_at
      }
    end
  end

  defp show_entries(counting, user_id) do
    episode_rows = Enum.filter(counting, &(not is_nil(&1.episode_id)))
    episode_ids = Enum.map(episode_rows, & &1.episode_id)
    episode_to_show = load_episode_show_ids(episode_ids)

    sort_at_by_show =
      episode_rows
      |> Enum.group_by(&Map.get(episode_to_show, &1.episode_id))
      |> Map.delete(nil)
      |> Map.new(fn {show_id, rows} ->
        {show_id, rows |> Enum.map(& &1.last_watched_at) |> Enum.max(DateTime)}
      end)

    show_ids = Map.keys(sort_at_by_show)
    shows = show_ids |> load_media_items() |> Map.new(&{&1.id, &1})
    episodes_by_show = load_episodes_with_files(show_ids)

    all_episode_ids =
      episodes_by_show |> Map.values() |> List.flatten() |> Enum.map(& &1.id)

    progress_by_episode = load_progress_for_episodes(user_id, all_episode_ids)

    for show_id <- show_ids,
        show = Map.get(shows, show_id),
        not is_nil(show),
        entry =
          build_show_entry(
            show,
            Map.get(episodes_by_show, show_id, []),
            progress_by_episode,
            sort_at_by_show[show_id]
          ),
        not is_nil(entry) do
      entry
    end
  end

  defp build_show_entry(show, episodes, progress_by_episode, sort_at) do
    progress_map =
      Enum.reduce(episodes, %{}, fn episode, acc ->
        case Map.get(progress_by_episode, episode.id) do
          nil -> acc
          progress -> Map.put(acc, episode.id, progress)
        end
      end)

    case NextEpisode.determine(episodes, progress_map) do
      {:continue, episode} ->
        episode_entry(show, episode, :continue, Map.get(progress_map, episode.id), sort_at)

      {state, episode} when state in [:next, :start] ->
        # `:start` means the progress map was empty, which normally means a
        # never-started show. Engagement was already established from the
        # show's full row set, so this is the trashed-file case: the watched
        # episode lost its file and dropped out of the map. It is a `:next`.
        episode_entry(show, episode, :next, Map.get(progress_map, episode.id), sort_at)

      _ ->
        nil
    end
  end

  defp episode_entry(show, episode, state, progress, sort_at) do
    %OnDeckEntry{
      kind: :episode,
      state: state,
      episode: episode,
      show: show,
      progress: progress,
      files: episode.media_files,
      sort_at: sort_at
    }
  end

  defp load_media_items([]), do: []

  defp load_media_items(ids) do
    Repo.all(from(m in MediaItem, where: m.id in ^ids))
  end

  defp load_movie_files([]), do: %{}

  defp load_movie_files(ids) do
    from(mf in MediaFile,
      where: mf.media_item_id in ^ids and is_nil(mf.trashed_at)
    )
    |> Repo.all()
    |> Enum.group_by(& &1.media_item_id)
  end

  defp load_episode_show_ids([]), do: %{}

  defp load_episode_show_ids(ids) do
    from(e in Episode, where: e.id in ^ids, select: {e.id, e.media_item_id})
    |> Repo.all()
    |> Map.new()
  end

  defp load_episodes_with_files([]), do: %{}

  defp load_episodes_with_files(show_ids) do
    active_files = from(mf in MediaFile, where: is_nil(mf.trashed_at))

    from(e in Episode,
      where: e.media_item_id in ^show_ids,
      order_by: [asc: e.season_number, asc: e.episode_number],
      preload: [media_files: ^active_files]
    )
    |> Repo.all()
    |> Enum.filter(&(&1.media_files != []))
    |> Enum.group_by(& &1.media_item_id)
  end

  defp load_progress_for_episodes(_user_id, []), do: %{}

  defp load_progress_for_episodes(user_id, episode_ids) do
    from(p in Progress,
      where: p.user_id == ^user_id and p.episode_id in ^episode_ids,
      select: {p.episode_id, p}
    )
    |> Repo.all()
    |> Map.new()
  end
end
