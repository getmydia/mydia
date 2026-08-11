defmodule Mydia.Playback do
  @moduledoc """
  Context for managing playback progress.
  """

  import Ecto.Query, warn: false
  alias Mydia.Events
  alias Mydia.Repo
  alias Mydia.Playback.Progress

  # Throttle for `playback.progressed` emission (R19): a `progressed` event is
  # only emitted when the completion percentage crosses a bucket boundary, so a
  # burst of position writes within the same 5% band yields at most one event.
  @progress_bucket_size 5.0

  @doc """
  Gets playback progress for a specific user and content (movie or episode).

  Returns nil if no progress exists.

  ## Examples

      iex> get_progress(user_id, media_item_id: media_item_id)
      %Progress{}

      iex> get_progress(user_id, episode_id: episode_id)
      %Progress{}

      iex> get_progress(user_id, media_item_id: non_existent_id)
      nil

  """
  def get_progress(user_id, media_item_id: media_item_id) do
    Repo.get_by(Progress, user_id: user_id, media_item_id: media_item_id)
  end

  def get_progress(user_id, episode_id: episode_id) do
    Repo.get_by(Progress, user_id: user_id, episode_id: episode_id)
  end

  @doc """
  Saves or updates playback progress for a user and content (movie or episode).

  Uses upsert logic to either create new progress or update existing.

  ## Examples

      iex> save_progress(user_id, [media_item_id: id], %{position_seconds: 120, duration_seconds: 3600})
      {:ok, %Progress{}}

      iex> save_progress(user_id, [episode_id: id], %{position_seconds: 120, duration_seconds: 3600})
      {:ok, %Progress{}}

      iex> save_progress(user_id, [media_item_id: id], %{position_seconds: -1})
      {:error, %Ecto.Changeset{}}

  """
  def save_progress(user_id, content_id, attrs, opts \\ []) when is_list(content_id) do
    origin = Keyword.get(opts, :origin, "player")

    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.merge(Map.new(content_id))

    previous = get_progress(user_id, content_id)

    result =
      case previous do
        nil ->
          %Progress{}
          |> Progress.changeset(attrs)
          |> Repo.insert()

        existing_progress ->
          existing_progress
          |> Progress.changeset(attrs)
          |> Repo.update()
      end

    case result do
      {:ok, progress} ->
        emit_progress_event(user_id, content_id, previous, progress, origin)
        {:ok, progress}

      error ->
        error
    end
  end

  @doc """
  Lists all playback progress for a user.

  ## Options

    * `:watched` - Filter by watched status (true/false)
    * `:limit` - Limit number of results
    * `:order_by` - Order results (:last_watched_at, :inserted_at)

  ## Examples

      iex> list_user_progress(user_id)
      [%Progress{}, ...]

      iex> list_user_progress(user_id, watched: false, limit: 10)
      [%Progress{}, ...]

  """
  def list_user_progress(user_id, opts \\ []) do
    query =
      from p in Progress,
        where: p.user_id == ^user_id

    query =
      if opts[:watched] != nil do
        from p in query, where: p.watched == ^opts[:watched]
      else
        query
      end

    query =
      case opts[:order_by] do
        :inserted_at ->
          from p in query, order_by: [desc: p.inserted_at]

        _ ->
          from p in query, order_by: [desc: p.last_watched_at]
      end

    query =
      if opts[:limit] do
        from p in query, limit: ^opts[:limit]
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns one keyset page of progress rows for the given users, enriched with the
  associations a sync plugin needs (the `playback_progress` data-list namespace,
  U5): the movie's external ids, or the episode's coordinates plus its show's
  external ids. Ordered by `(updated_at, id)`.

  ## Options
    * `:limit` - page size (default 200)
    * `:updated_since` - only rows updated at/after this `DateTime`
    * `:after` - `{updated_at, id}` of the last row of the previous page
  """
  @spec list_user_progress_page([binary()], keyword()) :: [Progress.t()]
  def list_user_progress_page(user_ids, opts \\ []) when is_list(user_ids) do
    limit = Keyword.get(opts, :limit, 200)
    since = Keyword.get(opts, :updated_since)
    after_cursor = Keyword.get(opts, :after)

    query =
      from p in Progress,
        where: p.user_id in ^user_ids,
        order_by: [asc: p.updated_at, asc: p.id],
        limit: ^limit,
        preload: [:media_item, episode: :media_item]

    query = if since, do: from(p in query, where: p.updated_at >= ^since), else: query

    query =
      case after_cursor do
        {ts, id} ->
          from p in query, where: p.updated_at > ^ts or (p.updated_at == ^ts and p.id > ^id)

        _ ->
          query
      end

    Repo.all(query)
  end

  @doc """
  Marks content as watched for a user.

  ## Examples

      iex> mark_watched(user_id, media_item_id: id)
      {:ok, %Progress{}}

      iex> mark_watched(user_id, episode_id: id)
      {:ok, %Progress{}}

  """
  def mark_watched(user_id, content_id, opts \\ []) do
    origin = Keyword.get(opts, :origin, "player")
    previous = get_progress(user_id, content_id)

    result =
      case previous do
        nil ->
          {:error, :not_found}

        existing_progress ->
          existing_progress
          |> Progress.changeset(%{watched: true})
          |> Repo.update()
      end

    case result do
      {:ok, progress} ->
        # `finished` is idempotent: only emit on the unwatched -> watched edge,
        # so re-marking an already-watched row is a silent no-op (R14 echo guard).
        unless previous_watched?(previous) do
          Events.playback_event("finished", user_id, content_id, playback_meta(progress, origin))
        end

        result

      _ ->
        result
    end
  end

  @doc """
  Idempotently marks content watched for a user, the origin-tagged write-back
  entry used by the plugin `ensure-watched` host function (U6) and the same
  synthetic-progress idiom the media-server sync uses.

  Returns `:already_watched` when the row is already watched (no write, no
  event), or `:changed` when a row was created (synthetic `position 0 /
  duration 1 / watched: true`) or an existing row flipped to watched.

  ## Options
    * `:origin` - the write origin (default `"player"`); plugins pass
      `"plugin:<slug>"` so the dispatcher suppresses the echo (R14)
    * `:watched_at` - the `DateTime` the watch happened (defaults to now)
  """
  @spec ensure_watched(binary(), keyword(), keyword()) :: :already_watched | :changed
  def ensure_watched(user_id, content_id, opts \\ []) when is_list(content_id) do
    origin = Keyword.get(opts, :origin, "player")
    watched_at = Keyword.get(opts, :watched_at)

    case get_progress(user_id, content_id) do
      %{watched: true} ->
        :already_watched

      nil ->
        attrs = %{position_seconds: 0, duration_seconds: 1, watched: true}
        attrs = if watched_at, do: Map.put(attrs, :last_watched_at, watched_at), else: attrs
        {:ok, _} = save_progress(user_id, content_id, attrs, origin: origin)
        :changed

      _existing ->
        {:ok, _} = mark_watched(user_id, content_id, origin: origin)
        :changed
    end
  end

  @doc """
  Deletes playback progress for a user and content.

  Useful for "Mark as Unwatched" functionality.

  ## Examples

      iex> delete_progress(user_id, media_item_id: id)
      {:ok, %Progress{}}

      iex> delete_progress(user_id, episode_id: id)
      {:ok, %Progress{}}

      iex> delete_progress(user_id, media_item_id: non_existent_id)
      {:error, :not_found}

  """
  def delete_progress(user_id, content_id) do
    case get_progress(user_id, content_id) do
      nil ->
        {:error, :not_found}

      existing_progress ->
        Repo.delete(existing_progress)
    end
  end

  @doc """
  Marks every episode in a season watched for a user.

  Loads the season's episodes (ordered by `episode_number`) and idempotently
  marks each via `ensure_watched/3`, so already-watched episodes are not
  re-stamped and emit no duplicate `"finished"` event. Returns `:ok` once the
  whole season has been processed; an empty or non-existent season is a no-op.

  ## Options
    * `:origin` - the write origin forwarded to `ensure_watched/3` (default
      `"player"`)
    * `:watched_at` - the `DateTime` the watch happened, forwarded to
      `ensure_watched/3`
  """
  @spec mark_season_watched(binary(), binary(), integer(), keyword()) :: :ok
  def mark_season_watched(user_id, show_id, season_number, opts \\ []) do
    show_id
    |> season_episode_ids(season_number)
    |> Enum.each(&ensure_watched(user_id, [episode_id: &1], opts))
  end

  @doc """
  Marks every episode in a season unwatched for a user.

  Loads the season's episodes and deletes each progress row via
  `delete_progress/2`, treating `:not_found` as success. This discards any
  in-progress resume positions in the season (the accepted Plex-model
  consequence) and emits no event, consistent with `delete_progress/2`.
  Returns `:ok` once the whole season is cleared, or `{:error, reason}` if a
  delete fails unexpectedly (e.g. `Repo.delete/1` returns a changeset error).
  """
  @spec mark_season_unwatched(binary(), binary(), integer()) :: :ok | {:error, term()}
  def mark_season_unwatched(user_id, show_id, season_number) do
    show_id
    |> season_episode_ids(season_number)
    |> Enum.reduce_while(:ok, fn episode_id, :ok ->
      case delete_progress(user_id, episode_id: episode_id) do
        {:ok, _progress} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Marks the anchor episode and all earlier episodes in its season watched.

  Resolves the anchor episode's show and season, loads that season's episodes,
  filters to those with `episode_number <= anchor.episode_number`, and marks
  each via `ensure_watched/3`. Season-scoped and inclusive — it never crosses
  season boundaries. Returns `:ok` (a missing episode is a no-op).

  ## Options
    * `:origin` / `:watched_at` - forwarded to `ensure_watched/3`
  """
  @spec mark_episodes_up_to_watched(binary(), binary(), keyword()) :: :ok
  def mark_episodes_up_to_watched(user_id, episode_id, opts \\ []) do
    case Repo.get(Mydia.Media.Episode, episode_id) do
      nil ->
        :ok

      anchor ->
        anchor.media_item_id
        |> season_episodes(anchor.season_number)
        |> Enum.filter(&(&1.episode_number <= anchor.episode_number))
        |> Enum.each(&ensure_watched(user_id, [episode_id: &1.id], opts))
    end
  end

  defp season_episodes(show_id, season_number) do
    Mydia.Media.list_episodes(show_id, season: season_number)
  end

  defp season_episode_ids(show_id, season_number) do
    show_id
    |> season_episodes(season_number)
    |> Enum.map(& &1.id)
  end

  @doc """
  Gets the next episode to watch for a TV series.

  Returns a tuple with the watch state and episode:
  - {:continue, episode} - There's an episode in progress (< 90% watched)
  - {:next, episode} - Next unwatched episode after the last watched
  - {:start, episode} - No progress, returns first episode
  - :all_watched - All episodes are watched

  ## Examples

      iex> get_next_episode(media_item_id, user_id)
      {:continue, %Episode{}}

      iex> get_next_episode(media_item_id, user_id)
      {:next, %Episode{}}

      iex> get_next_episode(media_item_id, user_id)
      :all_watched

  """
  def get_next_episode(media_item_id, user_id) do
    alias Mydia.Media

    active_files_query =
      from(mf in Mydia.Library.MediaFile, where: is_nil(mf.trashed_at))

    # Get all episodes for the series, ordered by season and episode number
    episodes =
      from(e in Media.Episode,
        where: e.media_item_id == ^media_item_id,
        order_by: [asc: e.season_number, asc: e.episode_number],
        preload: [media_files: ^active_files_query]
      )
      |> Repo.all()

    # Filter out episodes without media files
    episodes_with_files = Enum.filter(episodes, fn ep -> ep.media_files != [] end)

    if Enum.empty?(episodes_with_files) do
      nil
    else
      # Get progress for all episodes
      episode_ids = Enum.map(episodes_with_files, & &1.id)

      progress_map =
        from(p in Progress,
          where: p.user_id == ^user_id and p.episode_id in ^episode_ids,
          select: {p.episode_id, p}
        )
        |> Repo.all()
        |> Map.new()

      # Find the next episode to watch
      determine_next_episode(episodes_with_files, progress_map)
    end
  end

  # Helper function to determine which episode to play next
  defp determine_next_episode(episodes, progress_map) do
    # First, check for in-progress episodes (< 90% completion)
    in_progress_episode =
      Enum.find(episodes, fn episode ->
        case Map.get(progress_map, episode.id) do
          %Progress{watched: false, completion_percentage: pct} when pct < 90.0 -> true
          _ -> false
        end
      end)

    if in_progress_episode do
      {:continue, in_progress_episode}
    else
      # Find the first unwatched episode (no progress or not marked as watched)
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
          # All episodes watched
          :all_watched

        episode ->
          # Check if there's any progress at all
          has_any_progress? = progress_map != %{}

          if has_any_progress? do
            {:next, episode}
          else
            {:start, episode}
          end
      end
    end
  end

  @doc """
  Clears recent watch history for all users.
  """
  def clear_recent_history do
    Repo.delete_all(Progress)
    :ok
  end

  @doc """
  Lists recent watch history for all users.
  """
  def list_recent_history(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    since = Keyword.get(opts, :since)

    query =
      from p in Progress,
        order_by: [desc: p.last_watched_at],
        limit: ^limit,
        preload: [:user, :media_item, :episode]

    query =
      if since do
        from p in query, where: p.last_watched_at >= ^since
      else
        query
      end

    Repo.all(query)
  end

  # ── Playback Events (U1) ─────────────────────────────────────────────

  # Emit at most one playback event per `save_progress`: `finished` when the
  # write crosses the unwatched -> watched edge (the 90% auto-mark or an
  # explicit `watched: true`), otherwise `progressed` when the completion
  # percentage crosses a bucket boundary (R19 throttle), otherwise nothing.
  defp emit_progress_event(user_id, content_id, previous, progress, origin) do
    cond do
      watched_transition?(previous, progress) ->
        Events.playback_event("finished", user_id, content_id, playback_meta(progress, origin))

      bucket_crossed?(previous, progress) ->
        Events.playback_event("progressed", user_id, content_id, playback_meta(progress, origin))

      true ->
        :ok
    end
  end

  defp watched_transition?(previous, progress) do
    progress.watched == true and previous_watched?(previous) == false
  end

  defp previous_watched?(nil), do: false
  defp previous_watched?(%Progress{watched: watched}), do: watched == true

  defp bucket_crossed?(previous, progress) do
    progress_bucket(previous) != progress_bucket(progress)
  end

  defp progress_bucket(nil), do: -1
  defp progress_bucket(%Progress{completion_percentage: nil}), do: -1

  defp progress_bucket(%Progress{completion_percentage: pct}),
    do: trunc(pct / @progress_bucket_size)

  defp playback_meta(%Progress{} = progress, origin) do
    %{
      "position_seconds" => progress.position_seconds,
      "duration_seconds" => progress.duration_seconds,
      "completion_percentage" => progress.completion_percentage,
      "watched" => progress.watched,
      "origin" => origin
    }
  end
end
