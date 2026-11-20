defmodule Mydia.Indexers.RateLimiter do
  @moduledoc """
  Rate limiting system for indexer API requests.

  This module tracks API requests per indexer and enforces configurable
  rate limits to prevent API abuse and bans. Uses ETS for fast, concurrent
  request tracking with sliding window algorithm.

  ## Rate Limiting Strategy

  - Uses a sliding window approach for accurate rate limiting
  - Tracks individual searches as slots with timestamps in ETS
  - Automatically cleans up expired records
  - Each indexer can have its own rate limit configuration
  - Tracks a cooldown per indexer after it answers HTTP 429, on a ladder
    that grows while 429s keep coming and resets on the next success

  ## Usage

      # Take a search slot (the slot counts whether or not the search works)
      case RateLimiter.take_search_slot(indexer_id, rate_limit) do
        :ok ->
          do_api_call()

        {:error, :limited, _count} ->
          {:error, "Rate limit exceeded"}
      end

  Nothing here is persisted: all state lives in ETS and resets on restart.
  """

  use GenServer
  require Logger

  @table_name :indexer_rate_limits
  @cleanup_interval :timer.minutes(5)

  # Cooldown after a 429, indexed by how many 429s in a row (each one after
  # the previous cooldown ended) the indexer has answered. Stays at the last
  # step.
  @cooldown_ladder_ms [60_000, 300_000, 900_000, 1_800_000, 3_600_000, 10_800_000, 21_600_000]
  @max_cooldown_level length(@cooldown_ladder_ms) - 1
  @max_retry_after_ms :timer.hours(24)
  # A cooldown that ended this long ago no longer steps the ladder.
  @cooldown_idle_ms :timer.hours(24)
  # A Retry-After hint is ignored once it is older than this.
  @retry_hint_max_age_ms :timer.minutes(5)

  ## Client API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Takes one of the indexer's per-minute search slots before a search.

  `limit` is the indexer's searches per minute; `nil` or `<= 0` means no
  limit. Returns `:ok`, or `{:error, :limited, count}` without taking a slot.
  The slot is taken atomically (see `reserve_window/3`) and counts whether or
  not the search then succeeds.
  """
  @spec take_search_slot(String.t(), integer() | nil) ::
          :ok | {:error, :limited, non_neg_integer()}
  def take_search_slot(_indexer_id, nil), do: :ok
  def take_search_slot(_indexer_id, limit) when limit <= 0, do: :ok

  def take_search_slot(indexer_id, limit) when is_integer(limit),
    do: reserve_window({:search, indexer_id}, limit, :timer.minutes(1))

  @doc """
  Returns when the indexer's 429 cooldown ends, or `nil` when it has none.
  """
  @spec cooldown_until(String.t()) :: DateTime.t() | nil
  def cooldown_until(indexer_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, {:cooldown, indexer_id}) do
      [{_key, {until_mono, _level, until_utc}}] when until_mono > now -> to_datetime(until_utc)
      _ -> nil
    end
  end

  @doc """
  Records that the indexer answered HTTP 429 and returns when its cooldown ends.

  The cooldown is the current ladder step (1 minute, then 5, 15, 30 minutes,
  1, 3 and 6 hours) or `retry_after_ms` (capped at 24 hours), whichever is
  longer. When `retry_after_ms` is `nil`, a hint left by `note_retry_after/2`
  is used instead, once.

  A 429 that arrives while a cooldown is still running does not step the
  ladder: the cooldown keeps the later of its current end and the new one.
  The next 429 after it ended steps up one rung.
  """
  @spec record_rate_limited(String.t(), non_neg_integer() | nil) :: DateTime.t()
  def record_rate_limited(indexer_id, retry_after_ms) do
    # Taken either way, so a hint never outlives the 429 it was noted for.
    hint = take_retry_hint(indexer_id)
    retry_ms = min(retry_after_ms || hint || 0, @max_retry_after_ms)
    store_cooldown({:cooldown, indexer_id}, retry_ms)
  end

  # A hint older than @retry_hint_max_age_ms belongs to some earlier 429 whose
  # error never reached record_rate_limited/2, so it is dropped unused. A fresh
  # hint yields what is left of its wait, counted from when it was noted.
  defp take_retry_hint(indexer_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.take(@table_name, {:retry_hint, indexer_id}) do
      [{_key, hint}] -> if fresh_hint?(hint, now), do: max(hint_end(hint) - now, 0)
      [] -> nil
    end
  end

  defp fresh_hint?({_ms, noted_at}, now), do: now - noted_at <= @retry_hint_max_age_ms
  defp hint_end({ms, noted_at}), do: noted_at + ms

  defp store_cooldown(key, retry_ms) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, key) do
      [] ->
        entry = cooldown_entry(now, now + cooldown_wait(0, retry_ms), 0)

        if :ets.insert_new(@table_name, {key, entry}),
          do: entry_datetime(entry),
          else: store_cooldown(key, retry_ms)

      [{^key, {until_mono, level, _until_utc} = old}] when until_mono > now ->
        new_until = max(until_mono, now + cooldown_wait(level, retry_ms))

        if new_until == until_mono,
          do: entry_datetime(old),
          else: replace_cooldown(key, old, cooldown_entry(now, new_until, level), retry_ms)

      [{^key, {_until_mono, level, _until_utc} = old}] ->
        level = min(level + 1, @max_cooldown_level)
        entry = cooldown_entry(now, now + cooldown_wait(level, retry_ms), level)
        replace_cooldown(key, old, entry, retry_ms)
    end
  end

  # Swaps `old` for `new` only if nobody changed the entry since it was read,
  # else starts over from the entry that won.
  defp replace_cooldown(key, old, new, retry_ms) do
    spec = [{{key, old}, [], [{{{:const, key}, {:const, new}}}]}]

    case :ets.select_replace(@table_name, spec) do
      1 -> entry_datetime(new)
      _lost -> store_cooldown(key, retry_ms)
    end
  end

  defp cooldown_wait(level, retry_ms), do: max(Enum.at(@cooldown_ladder_ms, level), retry_ms)

  # The wall-clock end is stored as integer milliseconds beside the monotonic
  # one, so the whole entry stays a plain term `select_replace` can match.
  defp cooldown_entry(now_mono, until_mono, level),
    do: {until_mono, level, System.os_time(:millisecond) + (until_mono - now_mono)}

  defp entry_datetime({_until_mono, _level, until_utc}), do: to_datetime(until_utc)

  defp to_datetime(ms), do: DateTime.from_unix!(ms, :millisecond)

  @doc false
  # Test hook: ends the indexer's cooldown now while keeping its ladder step.
  @spec expire_cooldown(String.t()) :: :ok
  def expire_cooldown(indexer_id) do
    key = {:cooldown, indexer_id}

    case :ets.lookup(@table_name, key) do
      [{^key, {_until_mono, level, _until_utc}}] ->
        :ets.insert(
          @table_name,
          {key, {System.monotonic_time(:millisecond), level, System.os_time(:millisecond)}}
        )

        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Records a successful search: clears the cooldown and resets the ladder.
  """
  @spec record_success(String.t()) :: :ok
  def record_success(indexer_id) do
    :ets.delete(@table_name, {:cooldown, indexer_id})
    :ets.delete(@table_name, {:retry_hint, indexer_id})
    :ets.insert(@table_name, {{:success, indexer_id}, DateTime.utc_now()})
    :ok
  end

  @doc """
  Returns when the indexer last searched successfully since the app started,
  or `nil`.
  """
  @spec last_success_at(String.t()) :: DateTime.t() | nil
  def last_success_at(indexer_id) do
    case :ets.lookup(@table_name, {:success, indexer_id}) do
      [{_key, at}] -> at
      [] -> nil
    end
  end

  @doc """
  Notes a Retry-After seen where the 429 error itself cannot carry it.

  The next `record_rate_limited/2` call without its own Retry-After uses it
  and deletes it, unless the hint is more than 5 minutes old by then.

  A hint never shortens a fresh one already noted: of the two, the one whose
  wait ends later is kept, so a short answer to one concurrent search cannot
  erase a long pause another was told to take.
  """
  @spec note_retry_after(String.t(), non_neg_integer()) :: :ok
  def note_retry_after(indexer_id, ms) when is_integer(ms) and ms >= 0,
    do: put_retry_hint(indexer_id, ms, System.monotonic_time(:millisecond))

  @doc false
  # Test hook: notes a hint as if at monotonic time `noted_at` (milliseconds).
  @spec put_retry_hint(String.t(), non_neg_integer(), integer()) :: :ok
  def put_retry_hint(indexer_id, ms, noted_at) do
    key = {:retry_hint, indexer_id}
    new = {ms, noted_at}

    case :ets.lookup(@table_name, key) do
      [] ->
        if :ets.insert_new(@table_name, {key, new}),
          do: :ok,
          else: put_retry_hint(indexer_id, ms, noted_at)

      [{^key, old}] ->
        if fresh_hint?(old, System.monotonic_time(:millisecond)) and
             hint_end(old) >= hint_end(new) do
          :ok
        else
          replace_retry_hint(key, old, new)
        end
    end
  end

  # Swaps `old` for `new` only if no other process changed the hint since it
  # was read, else compares again against the hint that won.
  defp replace_retry_hint({:retry_hint, indexer_id} = key, old, {ms, noted_at} = new) do
    spec = [{{key, old}, [], [{{{:const, key}, {:const, new}}}]}]

    case :ets.select_replace(@table_name, spec) do
      1 -> :ok
      _lost -> put_retry_hint(indexer_id, ms, noted_at)
    end
  end

  @doc """
  Checks a rolling-window counter: `{:ok, count}` while fewer than `limit`
  events were recorded under `key` in the last `window_ms`, else
  `{:error, :limited, count}`.

  Unlike the per-minute limit above, the window is the caller's (the daily
  tracker caps in `Mydia.Indexers.TrackerLimits` use 24 hours). Counts live in
  ETS and reset when the application restarts.
  """
  @spec check_window(term(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :limited, non_neg_integer()}
  def check_window(key, limit, window_ms) do
    count = count_window(key, window_ms)
    if count < limit, do: {:ok, count}, else: {:error, :limited, count}
  end

  defp count_window(key, window_ms) do
    since = System.monotonic_time(:millisecond) - window_ms
    spec = [{{{:window, key, :"$1", :_}, :_}, [{:>=, :"$1", since}], [true]}]
    :ets.select_count(@table_name, spec)
  end

  @doc """
  Takes one slot under `key` if fewer than `limit` were taken in the last
  `window_ms`: `:ok`, or `{:error, :limited, count}` without taking it.

  The slot is inserted before counting and removed again when over the
  limit, so concurrent callers can never all pass a check for the last slot.
  At worst two racing callers both back off.

  Each slot expires `window_ms` after it was taken, so every call on one
  `key` must use the same window: a later check with a longer window would
  miss slots already cleaned up.
  """
  @spec reserve_window(term(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, :limited, non_neg_integer()}
  def reserve_window(key, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    slot = {:window, key, now, make_ref()}
    :ets.insert(@table_name, {slot, now + window_ms})

    case check_window(key, limit + 1, window_ms) do
      {:ok, _count} ->
        :ok

      {:error, :limited, count} ->
        :ets.delete(@table_name, slot)
        {:error, :limited, min(count - 1, limit)}
    end
  end

  @doc """
  Blocks until `delay_ms` has passed since the previous call for `indexer_id`.

  Slots are reserved atomically in ETS, so concurrent callers for one indexer
  queue up `delay_ms` apart instead of all sleeping the same interval. The first
  call (and any call after the delay has already elapsed) returns immediately.
  """
  @spec throttle(String.t(), non_neg_integer()) :: :ok
  def throttle(indexer_id, delay_ms) do
    :ok = throttle(indexer_id, delay_ms, :infinity)
  end

  @doc """
  Like `throttle/2`, but gives up instead of waiting longer than `max_wait_ms`.

  When the next slot is further away than `max_wait_ms` it returns
  `{:error, :over_budget}` without reserving the slot, so a refused caller does
  not push back the callers behind it.
  """
  @spec throttle(String.t(), non_neg_integer(), non_neg_integer() | :infinity) ::
          :ok | {:error, :over_budget}
  def throttle(_indexer_id, delay_ms, _max_wait) when delay_ms <= 0, do: :ok

  def throttle(indexer_id, delay_ms, max_wait) when is_integer(delay_ms) do
    key = {:throttle, indexer_id, :next}
    now = System.monotonic_time(:millisecond)

    if :ets.insert_new(@table_name, {key, now + delay_ms}) do
      :ok
    else
      reserve_slot(key, delay_ms, max_wait)
    end
  end

  defp reserve_slot(key, delay_ms, max_wait) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, key) do
      [{^key, next}] -> claim_slot(key, next, now, delay_ms, max_wait)
      [] -> throttle(elem(key, 1), delay_ms, max_wait)
    end
  end

  # Takes the slot after `next` if nobody else did in the meantime, else tries again.
  # Refuses without taking it when the wait would exceed `max_wait`.
  defp claim_slot(key, next, now, delay_ms, max_wait) do
    slot = max(next, now)

    if over_budget?(slot - now, max_wait) do
      {:error, :over_budget}
    else
      spec = [{{key, next}, [], [{{{:const, key}, slot + delay_ms}}]}]
      finish_claim(:ets.select_replace(@table_name, spec), key, slot - now, delay_ms, max_wait)
    end
  end

  defp finish_claim(1, _key, wait, _delay_ms, _max_wait) do
    if wait > 0, do: Process.sleep(wait)
    :ok
  end

  defp finish_claim(_lost, key, _wait, delay_ms, max_wait),
    do: reserve_slot(key, delay_ms, max_wait)

  defp over_budget?(_wait, :infinity), do: false
  defp over_budget?(wait, max_wait), do: wait > max_wait

  @doc """
  Gets statistics for rate limit usage.

  Returns the number of search slots taken in the last minute for the given
  indexer.

  ## Examples

      iex> get_stats("prowlarr-1")
      %{requests_last_minute: 5, window_start: 1234567890}
  """
  @spec get_stats(String.t()) :: map()
  def get_stats(indexer_id) do
    now = System.monotonic_time(:millisecond)
    window_ms = :timer.minutes(1)
    window_start = now - window_ms

    %{
      requests_last_minute: count_window({:search, indexer_id}, window_ms),
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
    keys = [{:cooldown, indexer_id}, {:success, indexer_id}, {:retry_hint, indexer_id}]
    Enum.each(keys, &:ets.delete(@table_name, &1))

    slots = [{{{:window, {:search, indexer_id}, :_, :_}, :_}, [], [true]}]
    deleted = :ets.select_delete(@table_name, slots)
    Logger.debug("Cleared rate limit state and #{deleted} search slots for indexer #{indexer_id}")

    {:reply, :ok, state}
  end

  ## Private Functions

  defp cleanup_old_requests do
    now = System.monotonic_time(:millisecond)

    # Two-element keys whose second element is a timestamp older than 2
    # minutes. The cooldown, success and retry-hint keys are also two-element
    # (`{:cooldown, id}`), but their second element is the indexer id, a
    # binary, and Erlang term order puts every binary after every number, so
    # this guard never deletes them.
    cutoff = now - :timer.minutes(2)
    match_spec = [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}]

    # Rolling-window events carry their own expiry.
    window_spec = [{{{:window, :_, :_, :_}, :"$1"}, [{:<, :"$1", now}], [true]}]

    # A cooldown that ended a day ago is idle: drop it so the ladder restarts.
    idle_cutoff = now - @cooldown_idle_ms
    cooldown_spec = [{{{:cooldown, :_}, {:"$1", :_, :_}}, [{:<, :"$1", idle_cutoff}], [true]}]

    deleted =
      :ets.select_delete(@table_name, match_spec) + :ets.select_delete(@table_name, window_spec) +
        :ets.select_delete(@table_name, cooldown_spec)

    if deleted > 0 do
      Logger.debug("Cleaned up #{deleted} old rate limit entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
