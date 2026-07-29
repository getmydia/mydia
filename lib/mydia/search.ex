defmodule Mydia.Search do
  @moduledoc """
  The Search context manages search-related functionality including
  exponential backoff for failed searches.

  ## Backoff Schedule

  When searches fail or return no usable results, exponential backoff is applied:

  15min → 30min → 1hr → 4hr → 12hr → 24hr → 3 days → 7 days (cap)

  ## Resource Types

  Backoff is tracked separately for different resource granularities:

  - `"movie"` - Per-movie, resource_id = media_item.id
  - `"tv_show"` - Per-show, resource_id = media_item.id
  - `"season"` - Per-season, resource_id = media_item.id, requires season_number option
  - `"episode"` - Per-episode, resource_id = episode.id

  ## Usage

      # Record a failure (increments backoff)
      Search.record_failure("episode", episode_id, "no_results")

      # Check if eligible for search
      if Search.eligible?("episode", episode_id) do
        # ... perform search
      end

      # Reset on success
      Search.reset_backoff("episode", episode_id)
  """

  import Ecto.Query, warn: false
  require Logger

  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Search.SearchBackoff

  # Backoff schedule in seconds: 15min, 30min, 1hr, 4hr, 12hr, 24hr, 3 days, 7 days
  @backoff_schedule [900, 1800, 3600, 14_400, 43_200, 86_400, 259_200, 604_800]

  @doc """
  Records a search failure and applies exponential backoff.

  Increments the failure count and calculates the next eligible search time
  based on the backoff schedule.

  ## Parameters

    - `resource_type` - Type of resource: "movie", "tv_show", "season", "episode"
    - `resource_id` - The resource UUID (media_item_id or episode_id)
    - `reason` - Brief description of failure (e.g., "no_results", "all_filtered")
    - `opts` - Optional parameters:
      - `:season_number` - Required for "season" resource_type

  ## Returns

    - `{:ok, backoff}` - The updated or created SearchBackoff record
    - `{:error, changeset}` - If the operation failed

  ## Examples

      iex> record_failure("episode", "episode-uuid", "no_results")
      {:ok, %SearchBackoff{failure_count: 1, ...}}

      iex> record_failure("season", "media-item-uuid", "all_filtered", season_number: 1)
      {:ok, %SearchBackoff{failure_count: 1, ...}}
  """
  def record_failure(resource_type, resource_id, reason, opts \\ []) do
    season_number = Keyword.get(opts, :season_number)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get_backoff(resource_type, resource_id, opts) do
      nil ->
        # First failure - create new backoff record
        create_backoff(%{
          resource_type: resource_type,
          resource_id: resource_id,
          season_number: season_number,
          failure_count: 1,
          last_failure_reason: reason,
          first_failed_at: now,
          next_eligible_at: calculate_next_eligible(1, now)
        })

      backoff ->
        # Increment failure count
        new_count = backoff.failure_count + 1

        update_backoff(backoff, %{
          failure_count: new_count,
          last_failure_reason: reason,
          next_eligible_at: calculate_next_eligible(new_count, now)
        })
    end
  end

  @doc """
  Resets the backoff state for a resource after a successful search/download.

  Deletes the backoff record, allowing immediate future searches.

  ## Parameters

    - `resource_type` - Type of resource: "movie", "tv_show", "season", "episode"
    - `resource_id` - The resource UUID
    - `opts` - Optional parameters:
      - `:season_number` - Required for "season" resource_type

  ## Returns

    - `{:ok, deleted_count}` - Number of records deleted (0 or 1)

  ## Examples

      iex> reset_backoff("episode", "episode-uuid")
      {:ok, 1}

      iex> reset_backoff("season", "media-item-uuid", season_number: 1)
      {:ok, 1}
  """
  def reset_backoff(resource_type, resource_id, opts \\ []) do
    season_number = Keyword.get(opts, :season_number)

    query = build_lookup_query(resource_type, resource_id, season_number)

    {count, _} = Repo.delete_all(query)

    if count > 0 do
      Logger.debug("Reset search backoff",
        resource_type: resource_type,
        resource_id: resource_id,
        season_number: season_number
      )
    end

    {:ok, count}
  end

  @doc """
  Checks if a resource is eligible for search (not in backoff or past backoff time).

  ## Parameters

    - `resource_type` - Type of resource: "movie", "tv_show", "season", "episode"
    - `resource_id` - The resource UUID
    - `opts` - Optional parameters:
      - `:season_number` - Required for "season" resource_type

  ## Returns

    - `true` if eligible for search
    - `false` if still in backoff period

  ## Examples

      iex> eligible?("episode", "episode-uuid")
      true

      iex> eligible?("season", "media-item-uuid", season_number: 1)
      false
  """
  def eligible?(resource_type, resource_id, opts \\ []) do
    case get_backoff(resource_type, resource_id, opts) do
      nil ->
        # No backoff record - eligible
        true

      %SearchBackoff{next_eligible_at: nil} ->
        # Backoff exists but no next_eligible_at - eligible
        true

      %SearchBackoff{next_eligible_at: next_eligible_at} ->
        # Check if we're past the backoff period
        now = DateTime.utc_now()
        DateTime.compare(now, next_eligible_at) != :lt
    end
  end

  @doc """
  Gets the current backoff state for a resource.

  ## Parameters

    - `resource_type` - Type of resource: "movie", "tv_show", "season", "episode"
    - `resource_id` - The resource UUID
    - `opts` - Optional parameters:
      - `:season_number` - Required for "season" resource_type

  ## Returns

    - `%SearchBackoff{}` if a backoff record exists
    - `nil` if no backoff record exists

  ## Examples

      iex> get_backoff("episode", "episode-uuid")
      %SearchBackoff{failure_count: 3, ...}

      iex> get_backoff("movie", "new-movie-uuid")
      nil
  """
  def get_backoff(resource_type, resource_id, opts \\ []) do
    season_number = Keyword.get(opts, :season_number)

    build_lookup_query(resource_type, resource_id, season_number)
    |> Repo.one()
  end

  @doc """
  Lists all resources currently in backoff for a given type.

  ## Parameters

    - `resource_type` - Type of resource: "movie", "tv_show", "season", "episode"

  ## Returns

    - List of `%SearchBackoff{}` records

  ## Examples

      iex> list_in_backoff("episode")
      [%SearchBackoff{}, ...]
  """
  def list_in_backoff(resource_type) do
    now = DateTime.utc_now()

    SearchBackoff
    |> where([b], b.resource_type == ^resource_type)
    |> where([b], b.next_eligible_at > ^now)
    |> order_by([b], asc: b.next_eligible_at)
    |> Repo.all()
  end

  @doc """
  Gets backoff information suitable for logging/events.

  Returns a map with human-readable backoff details.

  ## Parameters

    - `resource_type` - Type of resource
    - `resource_id` - The resource UUID
    - `opts` - Optional parameters including `:season_number`

  ## Returns

    - Map with backoff details or `nil` if no backoff exists
  """
  def get_backoff_info(resource_type, resource_id, opts \\ []) do
    case get_backoff(resource_type, resource_id, opts) do
      nil ->
        nil

      backoff ->
        %{
          failure_count: backoff.failure_count,
          last_failure_reason: backoff.last_failure_reason,
          first_failed_at: backoff.first_failed_at,
          next_eligible_at: backoff.next_eligible_at,
          backoff_duration_seconds: get_backoff_duration(backoff.failure_count)
        }
    end
  end

  @doc """
  Gets the backoff duration in seconds for a given failure count.
  """
  def get_backoff_duration(failure_count) when failure_count >= 1 do
    # Index is 0-based, failure_count is 1-based
    index = min(failure_count - 1, length(@backoff_schedule) - 1)
    Enum.at(@backoff_schedule, index)
  end

  def get_backoff_duration(_), do: 0

  @doc """
  Formats the backoff duration as a human-readable string.
  """
  def format_backoff_duration(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds} seconds"
      seconds < 3600 -> "#{div(seconds, 60)} minutes"
      seconds < 86_400 -> "#{div(seconds, 3600)} hours"
      true -> "#{div(seconds, 86_400)} days"
    end
  end

  @doc """
  Queues automatic release searches for the given media items.

  Movies queue `Mydia.Jobs.MovieSearch` in `"specific"` mode and TV shows queue
  `Mydia.Jobs.TVShowSearch` in `"show"` mode, the same jobs and modes the media
  detail page queues.

  Jobs are inserted one at a time with singular `Oban.insert/1`, not
  `Oban.insert_all/1`. On this project's engines (`Oban.Engines.Basic` for
  Postgres, `Oban.Engines.Lite` for SQLite, configured in `config/config.exs`)
  `insert_all/1` performs a raw bulk insert and never checks the workers'
  `unique: [period: 60, fields: [:args]]` option — bulk unique-job support is
  an Oban Pro (Smart Engine) feature this project does not use. Only the
  singular `insert/1` path checks uniqueness before inserting, so repeated
  calls within the window cannot double-queue. Do not change this back to
  `insert_all/1` as a "one round trip" optimization: that reintroduces
  duplicate-queuing on repeated clicks.

  Media items whose `type` is neither `"movie"` nor `"tv_show"` are skipped
  (and logged) rather than raising, so one unsupported item cannot fail the
  whole batch.

  Callers are expected to have filtered the list already, typically with
  `Mydia.Media.partition_for_auto_search/1`.

  Returns `{:ok, count}` with the number of jobs inserted, or `{:error,
  reason}` if any insert failed.
  """
  @spec queue_auto_searches([MediaItem.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def queue_auto_searches([]), do: {:ok, 0}

  def queue_auto_searches(items) when is_list(items) do
    items
    |> Enum.map(&auto_search_job/1)
    |> Enum.reject(&is_nil/1)
    |> insert_jobs(0)
  rescue
    error ->
      Logger.error("Failed to queue automatic searches: #{inspect(error)}")
      {:error, error}
  end

  defp insert_jobs([], count), do: {:ok, count}

  defp insert_jobs([changeset | rest], count) do
    # A deduped insert returns {:ok, %Oban.Job{conflict?: true}} rather than an
    # error, so it must not bump the "queued" count. This branch cannot be
    # regression-tested here: config/test.exs sets `engine: false`, so
    # insert_job/1 always falls through to the Repo.insert/1 rescue clause
    # below, which never sets conflict?: true.
    case insert_job(changeset) do
      {:ok, %Oban.Job{conflict?: true}} -> insert_jobs(rest, count)
      {:ok, _job} -> insert_jobs(rest, count + 1)
      {:error, _reason} = error -> error
    end
  end

  defp auto_search_job(%MediaItem{type: "movie", id: id}) do
    Mydia.Jobs.MovieSearch.new(%{mode: "specific", media_item_id: id})
  end

  defp auto_search_job(%MediaItem{type: "tv_show", id: id}) do
    Mydia.Jobs.TVShowSearch.new(%{mode: "show", media_item_id: id})
  end

  defp auto_search_job(%MediaItem{id: id, type: type}) do
    Logger.warning("Skipping auto search for unsupported media type",
      media_item_id: id,
      type: type
    )

    nil
  end

  # Insert an Oban job, falling back to a direct Repo insert when Oban's engine
  # is disabled (test mode). Mirrors the pattern in Downloads.Queue and
  # DownloadMonitor.
  #
  # This repo's test config sets `engine: false` (see config/test.exs), so
  # this fallback branch is the only one the test suite exercises. It gives
  # no signal on the real `Oban.insert/1` path or its uniqueness behavior.
  defp insert_job(changeset) do
    Oban.insert(changeset)
  rescue
    RuntimeError -> Repo.insert(changeset)
  end

  ## Private Functions

  defp create_backoff(attrs) do
    %SearchBackoff{}
    |> SearchBackoff.changeset(attrs)
    |> Repo.insert()
    |> tap_result(:created)
  end

  defp update_backoff(backoff, attrs) do
    backoff
    |> SearchBackoff.changeset(attrs)
    |> Repo.update()
    |> tap_result(:updated)
  end

  defp tap_result({:ok, backoff} = result, action) do
    Logger.debug("Search backoff #{action}",
      resource_type: backoff.resource_type,
      resource_id: backoff.resource_id,
      season_number: backoff.season_number,
      failure_count: backoff.failure_count,
      next_eligible_at: backoff.next_eligible_at
    )

    result
  end

  defp tap_result(error, _action), do: error

  defp calculate_next_eligible(failure_count, now) do
    duration = get_backoff_duration(failure_count)
    DateTime.add(now, duration, :second)
  end

  defp build_lookup_query(resource_type, resource_id, nil) do
    SearchBackoff
    |> where([b], b.resource_type == ^resource_type)
    |> where([b], b.resource_id == ^resource_id)
    |> where([b], is_nil(b.season_number))
  end

  defp build_lookup_query(resource_type, resource_id, season_number) do
    SearchBackoff
    |> where([b], b.resource_type == ^resource_type)
    |> where([b], b.resource_id == ^resource_id)
    |> where([b], b.season_number == ^season_number)
  end
end
