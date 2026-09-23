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

  On top of that, a viewer can take a title off the rail by hand, which writes
  a `Mydia.Playback.Dismissal` and hides the entry while the dismissal is newer
  than its most recent watch. Playing the title again is what brings it back,
  so nothing has to expire these. See `dismissed?/2`.
  """

  import Ecto.Query

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Playback.{Dismissal, NextEpisode, OnDeckEntry, Progress}
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

    dismissals = load_dismissals(user_id)

    # Ranked on lean rows, then hydrated: only the entries that make the rail
    # get their full episode and file rows. Loading them for every episode of
    # every engaged show cost ~200ms and 8MB on a real library to return ten.
    (movie_candidates(counting) ++ show_candidates(counting, user_id, min_position))
    |> Enum.reject(&dismissed?(&1, dismissals))
    |> Enum.sort_by(&sort_key/1, :desc)
    |> Enum.take(limit)
    |> hydrate()
  end

  # Rejected before `Enum.take/2`, so a hidden title does not silently eat one
  # of the caller's slots and leave a short rail.
  #
  # The comparison is against `sort_at`, the entry's most recent watch, which
  # is what makes the hide expire without a sweep: playing the title pushes
  # `sort_at` past `dismissed_at` and the card comes back. For a series
  # `sort_at` is the newest watch across the whole show, so finishing any
  # episode brings it back, not only the one the card happens to name.
  #
  # `:eq` counts as dismissed. Both columns are `:utc_datetime`, so two actions
  # in the same second are indistinguishable and one of them has to win. Giving
  # it to the dismissal keeps the gesture the viewer just made from appearing
  # to do nothing; the losing case (dismiss, then resume the same title inside
  # one second) rights itself on the next progress write a few seconds later.
  defp dismissed?(entry, dismissals) do
    case Map.get(dismissals, OnDeckEntry.dismissal_key(entry)) do
      nil -> false
      dismissed_at -> DateTime.compare(dismissed_at, entry.sort_at) != :lt
    end
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

  # Candidates carry `files: []` until `hydrate/1`. The has-a-file test that
  # used to read the loaded files is a membership check on ids instead.
  defp movie_candidates(counting) do
    candidates =
      Enum.filter(counting, fn progress ->
        not is_nil(progress.media_item_id) and progress.watched == false and
          (progress.completion_percentage || 0.0) < @watched_threshold
      end)

    ids = Enum.map(candidates, & &1.media_item_id)
    movies = ids |> load_media_items() |> Map.new(&{&1.id, &1})
    playable = movie_ids_with_files(ids)

    for progress <- candidates,
        movie = Map.get(movies, progress.media_item_id),
        not is_nil(movie),
        MapSet.member?(playable, movie.id) do
      %OnDeckEntry{
        kind: :movie,
        state: :continue,
        media_item: movie,
        progress: progress,
        sort_at: progress.last_watched_at
      }
    end
  end

  defp show_candidates(counting, user_id, min_position) do
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
    episodes_by_show = load_playable_episodes(show_ids)

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
            sort_at_by_show[show_id],
            min_position
          ),
        not is_nil(entry) do
      entry
    end
  end

  defp build_show_entry(show, episodes, progress_by_episode, sort_at, min_position) do
    progress_map =
      Enum.reduce(episodes, %{}, fn episode, acc ->
        case Map.get(progress_by_episode, episode.id) do
          nil -> acc
          progress -> Map.put(acc, episode.id, progress)
        end
      end)

    # The same floor that decided the show belongs on the rail also decides
    # which episode it names, so a row too small to count as viewing cannot
    # become the card's resume point.
    case NextEpisode.determine(episodes, progress_map, min_position_seconds: min_position) do
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

  # `episode` is a lean row from `load_playable_episodes/1` here; `hydrate/1`
  # swaps in the full struct and its files for the entries that survive.
  defp episode_entry(show, episode, state, progress, sort_at) do
    %OnDeckEntry{
      kind: :episode,
      state: state,
      episode: episode,
      show: show,
      progress: progress,
      sort_at: sort_at
    }
  end

  # Two queries at most, whatever the rail length. An entry whose episode or
  # files vanished between ranking and here (a file trashed mid-request) is
  # dropped rather than shipped with no playable file.
  defp hydrate(entries) do
    episodes =
      entries
      |> Enum.filter(&(&1.kind == :episode))
      |> Enum.map(& &1.episode.id)
      |> load_episodes_with_files()

    movie_files =
      entries
      |> Enum.filter(&(&1.kind == :movie))
      |> Enum.map(& &1.media_item.id)
      |> load_movie_files()

    Enum.flat_map(entries, fn
      %OnDeckEntry{kind: :episode} = entry ->
        case Map.get(episodes, entry.episode.id) do
          %Episode{media_files: [_ | _] = files} = episode ->
            [%{entry | episode: episode, files: files}]

          _ ->
            []
        end

      %OnDeckEntry{kind: :movie} = entry ->
        case Map.get(movie_files, entry.media_item.id, []) do
          [] -> []
          files -> [%{entry | files: files}]
        end
    end)
  end

  # One query for the whole user, never one per entry: the rail's query count
  # has to stay flat as a library grows, which `on_deck_query_count_test.exs`
  # pins down.
  defp load_dismissals(user_id) do
    from(d in Dismissal,
      where: d.user_id == ^user_id,
      select: {d.media_item_id, d.dismissed_at}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp load_media_items([]), do: []

  defp load_media_items(ids) do
    Repo.all(from(m in MediaItem, where: m.id in ^ids))
  end

  defp movie_ids_with_files([]), do: MapSet.new()

  defp movie_ids_with_files(ids) do
    # is_nil(extra_kind), via MediaFile.versions/0, so a bonus feature never
    # makes a movie playable on deck.
    from(mf in MediaFile.versions(),
      where: mf.media_item_id in ^ids,
      distinct: true,
      select: mf.media_item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp load_movie_files([]), do: %{}

  defp load_movie_files(ids) do
    from(mf in MediaFile.versions(), where: mf.media_item_id in ^ids)
    |> Repo.all()
    |> Enum.group_by(& &1.media_item_id)
  end

  defp load_playable_episodes([]), do: %{}

  # Only what `NextEpisode.determine/3` reads, in the order it requires, and
  # only episodes with an active file, which it also requires of its callers.
  defp load_playable_episodes(show_ids) do
    has_file =
      from(mf in MediaFile.versions(),
        where: mf.episode_id == parent_as(:episode).id,
        select: 1
      )

    from(e in Episode,
      as: :episode,
      where: e.media_item_id in ^show_ids,
      where: exists(has_file),
      order_by: [asc: e.season_number, asc: e.episode_number],
      select: %{
        id: e.id,
        media_item_id: e.media_item_id,
        season_number: e.season_number,
        episode_number: e.episode_number
      }
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

  defp load_episodes_with_files(ids) do
    from(e in Episode,
      where: e.id in ^ids,
      preload: [media_files: ^MediaFile.versions()]
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
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
