defmodule Mydia.Playback do
  @moduledoc """
  Context for managing playback progress.
  """

  import Ecto.Query, warn: false
  alias Mydia.Events
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Playback.Dismissal
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
    changeset_opts = Keyword.take(opts, [:authoritative_watched])

    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.merge(Map.new(content_id))

    previous = get_progress(user_id, content_id)

    result =
      case previous do
        nil ->
          %Progress{}
          |> Progress.changeset(attrs, changeset_opts)
          |> Repo.insert()

        existing_progress ->
          existing_progress
          |> Progress.changeset(attrs, changeset_opts)
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
  Best-known runtime in seconds for a content id, or nil.

  Used by sync imports, which carry a position from the remote but no duration.
  """
  @spec get_progress_duration(keyword()) :: integer() | nil
  def get_progress_duration(content_id) do
    case get_progress_any_user(content_id) do
      %{duration_seconds: d} when is_integer(d) and d > 0 -> d
      _ -> nil
    end
  end

  defp get_progress_any_user(media_item_id: id) do
    Progress |> where([p], p.media_item_id == ^id) |> limit(1) |> Repo.one()
  end

  defp get_progress_any_user(episode_id: id) do
    Progress |> where([p], p.episode_id == ^id) |> limit(1) |> Repo.one()
  end

  @doc """
  Deletes playback progress for a user and content.

  Useful for "Mark as Unwatched" functionality.

  ## Options

    * `:origin` - write origin for downstream event tagging (default unused here)

  ## Examples

      iex> delete_progress(user_id, media_item_id: id)
      {:ok, %Progress{}}

      iex> delete_progress(user_id, episode_id: id)
      {:ok, %Progress{}}

      iex> delete_progress(user_id, media_item_id: non_existent_id)
      {:error, :not_found}

  """
  def delete_progress(user_id, content_id, opts \\ [])

  def delete_progress(user_id, content_id, opts) when is_list(content_id) do
    case get_progress(user_id, content_id) do
      nil ->
        {:error, :not_found}

      existing_progress ->
        result = Repo.delete(existing_progress)

        # An unwatch deletes the row, so without this event nothing downstream
        # can ever learn it happened.
        with {:ok, _} <- result do
          Events.playback_event(
            "unwatched",
            user_id,
            content_id,
            playback_meta(existing_progress, Keyword.get(opts, :origin, "player"))
          )
        end

        result
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

    active_files_query = Mydia.Library.MediaFile.versions()

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

      Mydia.Playback.NextEpisode.determine(episodes_with_files, progress_map)
    end
  end

  @doc """
  Returns the user's Continue Watching entries, most recent first.

  See `Mydia.Playback.OnDeck.list/2` for the rule set and options.
  """
  @spec on_deck(binary(), keyword()) :: [Mydia.Playback.OnDeckEntry.t()]
  defdelegate on_deck(user_id, opts \\ []), to: Mydia.Playback.OnDeck, as: :list

  @doc """
  Hides a title from the user's Continue Watching rail.

  `media_item_id` is the movie, or for a series the *show* — never an episode.
  `Mydia.Playback.OnDeck` emits one card per show, so the show is the only unit
  a "remove this card" gesture can mean.

  This hides; it does not unwatch. The progress row is left alone, so the
  resume point survives, and **no event is emitted**. That silence is
  deliberate: `delete_progress/3` emits `playback.unwatched`, which
  `Mydia.WatchSync` forwards to Plex and Jellyfin, and taking a card off a rail
  must not tell another media server that a watched title was unwatched.

  An upsert rather than an insert. A dismissed show comes back the moment it is
  played again, so dismissing the same title twice is ordinary use and has to
  re-stamp rather than fail on the unique index.

  ## Options

    * `:now` - the clock, injectable so tests need not manipulate real time

  ## Examples

      iex> dismiss_from_on_deck(user_id, movie_id)
      {:ok, %Dismissal{}}

  """
  @spec dismiss_from_on_deck(binary(), binary(), keyword()) ::
          {:ok, Dismissal.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def dismiss_from_on_deck(user_id, media_item_id, opts \\ []) do
    if media_item_exists?(media_item_id) do
      now =
        opts
        |> Keyword.get(:now, DateTime.utc_now())
        |> DateTime.truncate(:second)

      insert_dismissal(user_id, media_item_id, now)
    else
      {:error, :not_found}
    end
  end

  # The lookup above cannot close the window on its own: a media item deleted
  # between the check and this insert takes the foreign key with it. Postgres
  # names the constraint so the changeset carries the error, SQLite does not and
  # `Repo.insert/2` raises, so the rescue is what makes the two agree. Either
  # way the answer is the one the check gives for an id that never existed.
  defp insert_dismissal(user_id, media_item_id, now) do
    %Dismissal{user_id: user_id, media_item_id: media_item_id}
    |> Dismissal.changeset(%{dismissed_at: now})
    |> Repo.insert(
      on_conflict: {:replace, [:dismissed_at, :updated_at]},
      conflict_target: [:user_id, :media_item_id]
    )
    |> case do
      {:error, %Ecto.Changeset{} = changeset} ->
        if missing_parent?(changeset), do: {:error, :not_found}, else: {:error, changeset}

      other ->
        other
    end
  rescue
    Ecto.ConstraintError -> {:error, :not_found}
  end

  defp missing_parent?(%Ecto.Changeset{errors: errors}) do
    Keyword.has_key?(errors, :media_item_id) or Keyword.has_key?(errors, :user_id)
  end

  # Checked here rather than left to the foreign key, because the two adapters
  # disagree about what a violation looks like: Postgres names the constraint
  # so Ecto can turn it into a changeset error, while SQLite reports no name at
  # all and `Repo.insert/2` raises `Ecto.ConstraintError` straight through the
  # resolver. An explicit lookup behaves the same on both.
  #
  # The near miss this guards is an episode id, which the rail invites: its
  # cards are episodes but its dismissals are shows.
  defp media_item_exists?(media_item_id) do
    Repo.exists?(from(m in MediaItem, where: m.id == ^media_item_id))
  rescue
    # A client is free to send any string as a GraphQL ID. One that is not a
    # UUID names nothing, which is the same answer as a UUID that names nothing.
    Ecto.Query.CastError -> false
  end

  @doc """
  Lists recent watch history for all users.

  This is progress rows ordered by `last_watched_at`, which is not the same as
  "recently watched here": a media-server sync writes progress for watches that
  happened on somebody else's box, and stamps that column with the sync time
  whenever the remote carries no timestamp. For plays that happened on this
  server, use `Mydia.Playback.Stats.recent_plays/1`.
  """
  def list_recent_history(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    since = Keyword.get(opts, :since)

    query =
      from p in Progress,
        order_by: [desc: p.last_watched_at],
        limit: ^limit,
        preload: [:user, :media_item, episode: [:media_item]]

    query =
      if since do
        from p in query, where: p.last_watched_at >= ^since
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Human-readable title for a progress row.

  Progress rows are XOR by `Progress.validate_one_parent/1`: a movie row
  carries `media_item`, an episode row carries `episode` and its show hangs off
  `episode.media_item`. Reading a show title off `media_item` therefore always
  finds `nil` on an episode row, which is what rendered every TV watch as
  "Unknown Media".
  """
  @spec progress_title(Progress.t()) :: String.t()
  def progress_title(%Progress{episode: %Episode{} = episode}), do: episode_label(episode)
  def progress_title(%Progress{media_item: %MediaItem{title: title}}), do: title
  def progress_title(%Progress{}), do: "Unknown Media"

  @doc """
  Poster path for a progress row, or nil when there is no artwork.

  An episode's poster is its show's, since episode stills are not what the
  activity list wants.
  """
  @spec progress_poster_path(Progress.t()) :: String.t() | nil
  def progress_poster_path(%Progress{episode: %Episode{media_item: %MediaItem{} = item}}),
    do: poster_path(item)

  def progress_poster_path(%Progress{media_item: %MediaItem{} = item}), do: poster_path(item)
  def progress_poster_path(%Progress{}), do: nil

  defp poster_path(%MediaItem{metadata: %{poster_path: path}}), do: path
  defp poster_path(_), do: nil

  defp episode_label(%Episode{media_item: %MediaItem{title: show_title}} = episode) do
    "#{show_title} - #{season_episode(episode)}"
  end

  defp episode_label(%Episode{} = episode), do: season_episode(episode)

  defp season_episode(%Episode{season_number: season, episode_number: number}) do
    "S#{pad2(season)}E#{pad2(number)}"
  end

  defp pad2(n), do: String.pad_leading("#{n}", 2, "0")

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
