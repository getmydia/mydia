defmodule Mydia.Indexers.RateLimiter do
  @moduledoc """
  Rate limiting system for indexer API requests.

  This module tracks API requests per indexer and enforces configurable
  rate limits to prevent API abuse and bans. Uses ETS for fast, concurrent
  request tracking with sliding window algorithm.

  ## Rate Limiting Strategy

  - Uses a sliding window approach for accurate rate limiting
  - Tracks individual requests with timestamps in ETS
  - Automatically cleans up expired request records
  - Each indexer can have its own rate limit configuration

  ## Usage

      # Check if request is allowed
      case RateLimiter.check_rate_limit(indexer_id, rate_limit) do
        :ok ->
          # Make the request
          RateLimiter.record_request(indexer_id)
          do_api_call()

        {:error, :rate_limited, retry_after} ->
          # Wait or reject
          {:error, "Rate limit exceeded, retry after \#{retry_after}ms"}
      end
  """

  use GenServer
  require Logger

  @table_name :indexer_rate_limits
  @cleanup_interval :timer.minutes(5)

  ## Client API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request can be made for the given indexer.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limited, retry_after_ms}`
  if the rate limit would be exceeded.

  ## Parameters

  - `indexer_id` - Unique identifier for the indexer
  - `rate_limit` - Maximum requests per minute (nil means no limit)

  ## Examples

      iex> check_rate_limit("prowlarr-1", 60)
      :ok

      iex> check_rate_limit("prowlarr-1", 1)
      {:error, :rate_limited, 45000}
  """
  @spec check_rate_limit(String.t(), integer() | nil) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check_rate_limit(_indexer_id, nil), do: :ok
  def check_rate_limit(_indexer_id, rate_limit) when rate_limit <= 0, do: :ok

  def check_rate_limit(indexer_id, rate_limit) when is_integer(rate_limit) do
    now = System.monotonic_time(:millisecond)
    window_start = now - :timer.minutes(1)

    # Count requests in the last minute
    request_count = count_requests(indexer_id, window_start)

    if request_count < rate_limit do
      :ok
    else
      # Calculate when the oldest request will expire
      retry_after = calculate_retry_after(indexer_id, window_start)
      {:error, :rate_limited, retry_after}
    end
  end

  @doc """
  Records a request for the given indexer.

  Should be called immediately after a successful rate limit check.

  ## Examples

      iex> record_request("prowlarr-1")
      :ok
  """
  @spec record_request(String.t()) :: :ok
  def record_request(indexer_id) do
    now = System.monotonic_time(:millisecond)
    # Store {indexer_id, timestamp} as the key for easy cleanup
    :ets.insert(@table_name, {{indexer_id, now}, true})
    :ok
  end

  @doc """
  Gets statistics for rate limit usage.

  Returns the number of requests made in the last minute for the given indexer.

  ## Examples

      iex> get_stats("prowlarr-1")
      %{requests_last_minute: 5, window_start: 1234567890}
  """
  @spec get_stats(String.t()) :: map()
  def get_stats(indexer_id) do
    now = System.monotonic_time(:millisecond)
    window_start = now - :timer.minutes(1)
    request_count = count_requests(indexer_id, window_start)

    %{
      requests_last_minute: request_count,
      window_start: window_start,
      current_time: now
    }
  end

  @doc """
  Clears all rate limit data for a specific indexer.

  Useful for testing or when an indexer is removed.
  """
  @spec clear_indexer(String.t()) :: :ok
  def clear_indexer(indexer_id) do
    GenServer.call(__MODULE__, {:clear_indexer, indexer_id})
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    # Create ETS table for tracking requests
    :ets.new(@table_name, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule periodic cleanup of old requests
    schedule_cleanup()

    Logger.info("Indexer rate limiter started")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_requests()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_call({:clear_indexer, indexer_id}, _from, state) do
    # Delete all entries for this indexer
    match_spec = [
      {{{:"$1", :_}, :_}, [{:==, :"$1", indexer_id}], [true]}
    ]

    deleted = :ets.select_delete(@table_name, match_spec)
    Logger.debug("Cleared #{deleted} rate limit entries for indexer #{indexer_id}")

    {:reply, :ok, state}
  end

  ## Private Functions

  defp count_requests(indexer_id, window_start) do
    match_spec = [
      {{{:"$1", :"$2"}, :_}, [{:andalso, {:==, :"$1", indexer_id}, {:>=, :"$2", window_start}}],
       [true]}
    ]

    :ets.select_count(@table_name, match_spec)
  end

  defp calculate_retry_after(indexer_id, window_start) do
    # Find the oldest request in the current window
    match_spec = [
      {{{:"$1", :"$2"}, :_}, [{:andalso, {:==, :"$1", indexer_id}, {:>=, :"$2", window_start}}],
       [:"$2"]}
    ]

    case :ets.select(@table_name, match_spec, 1) do
      {[oldest_timestamp], _continuation} ->
        # Time until this request falls out of the window
        now = System.monotonic_time(:millisecond)
        window_end = oldest_timestamp + :timer.minutes(1)
        max(0, window_end - now)

      :"$end_of_table" ->
        # No requests found, shouldn't happen but return 0
        0
    end
  end

  defp cleanup_old_requests do
    # Remove requests older than 2 minutes (beyond the sliding window)
    cutoff = System.monotonic_time(:millisecond) - :timer.minutes(2)

    match_spec = [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ]

    deleted = :ets.select_delete(@table_name, match_spec)

    if deleted > 0 do
      Logger.debug("Cleaned up #{deleted} old rate limit entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
