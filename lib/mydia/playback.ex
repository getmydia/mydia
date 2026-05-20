defmodule Mydia.Playback do
  @moduledoc """
  Context for managing playback progress.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Playback.Progress

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
  def save_progress(user_id, content_id, attrs) when is_list(content_id) do
    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.merge(Map.new(content_id))

    result =
      case get_progress(user_id, content_id) do
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
        maybe_scrobble(user_id, content_id, progress)
        maybe_promote_torrent(user_id, content_id, progress)
        {:ok, progress}

      error ->
        error
    end
  end

  defp maybe_promote_torrent(user_id, content_id, progress) do
    if progress.completion_percentage >= 90.0 do
      query =
        cond do
          content_id[:media_item_id] ->
            from s in Mydia.Streaming.Torrent.SessionSchema,
              where:
                s.user_id == ^user_id and s.media_item_id == ^content_id[:media_item_id] and
                  s.state != :completed

          content_id[:episode_id] ->
            from s in Mydia.Streaming.Torrent.SessionSchema,
              where:
                s.user_id == ^user_id and s.episode_id == ^content_id[:episode_id] and
                  s.state != :completed

          true ->
            nil
        end

      if query do
        Repo.all(query)
        |> Enum.each(fn session ->
          Mydia.Streaming.Torrent.check_and_promote(session.id)
        end)
      end
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
  Marks content as watched for a user.

  ## Examples

      iex> mark_watched(user_id, media_item_id: id)
      {:ok, %Progress{}}

      iex> mark_watched(user_id, episode_id: id)
      {:ok, %Progress{}}

  """
  def mark_watched(user_id, content_id) do
    result =
      case get_progress(user_id, content_id) do
        nil ->
          {:error, :not_found}

        existing_progress ->
          existing_progress
          |> Progress.changeset(%{watched: true})
          |> Repo.update()
      end

    case result do
      {:ok, _progress} ->
        # Push to Trakt history (fire-and-forget)
        maybe_push_trakt_history(user_id, content_id)
        result

      _ ->
        result
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
    episodes_with_files = Enum.filter(episodes, fn ep -> length(ep.media_files) > 0 end)

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
          %Progress{completion_percentage: pct} when pct < 90.0 -> true
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

  # ── Trakt Integration ────────────────────────────────────────────────

  defp maybe_scrobble(user_id, content_id, progress) do
    if Mydia.Integrations.trakt_scrobbling_enabled?(user_id) do
      pct = progress.completion_percentage || 0.0
      Mydia.Integrations.Trakt.Scrobbler.scrobble_progress(user_id, content_id, pct)
    end
  end

  defp maybe_push_trakt_history(user_id, content_id) do
    if Mydia.Integrations.trakt_enabled?(user_id) do
      Mydia.Integrations.Trakt.Scrobbler.scrobble_stop(user_id, content_id, 100.0)
    end
  end
end
