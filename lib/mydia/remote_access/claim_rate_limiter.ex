defmodule Mydia.RemoteAccess.ClaimRateLimiter do
  @moduledoc """
  Rate limiter for claim code validation attempts.
  Limits failed validation attempts per opaque key to prevent brute force
  attacks. An IP address is one kind of key.
  """
  use GenServer

  @table_name :claim_rate_limiter
  @max_attempts 5
  @window_seconds 3600

  # 1 hour

  # Client API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Atomically checks the rate limit and records an attempt.

  ## Options

    * `:max_attempts` - defaults to #{@max_attempts}
    * `:window_seconds` - defaults to #{@window_seconds}

  The p2p pairing path passes its own bounds, because its window is tied to the
  claim lifetime rather than to an hour of IP reputation.

  """
  def check_and_record(key, opts \\ []) when is_binary(key) do
    max_attempts = Keyword.get(opts, :max_attempts, @max_attempts)
    window_seconds = Keyword.get(opts, :window_seconds, @window_seconds)
    storage_key = rate_limit_key(key)
    now = System.system_time(:second)

    try do
      # Atomically increment the attempt counter (position 2 in tuple)
      new_count = :ets.update_counter(@table_name, storage_key, {2, 1})

      # Lookup to check window expiration (safe to read after atomic increment)
      [{^storage_key, _count, first_attempt_at}] = :ets.lookup(@table_name, storage_key)

      if now - first_attempt_at > window_seconds do
        # Window expired - reset atomically
        :ets.insert(@table_name, {storage_key, 1, now})
        :ok
      else
        if new_count > max_attempts do
          {:error, :rate_limited}
        else
          :ok
        end
      end
    catch
      # Key doesn't exist - try to insert atomically
      :error, :badarg ->
        # insert_new returns false if key already exists (another process inserted)
        case :ets.insert_new(@table_name, {storage_key, 1, now}) do
          true ->
            :ok

          false ->
            # Another process inserted first, retry with update_counter
            check_and_record(key, opts)
        end
    end
  end

  @doc """
  Checks if an IP address is allowed to attempt validation.
  Returns :ok if allowed, {:error, :rate_limited} if not.

  Note: Prefer using `check_and_record/1` which atomically checks and records
  the attempt in a single operation.
  """
  def check_rate_limit(ip_address) when is_binary(ip_address) do
    key = rate_limit_key(ip_address)
    now = System.system_time(:second)

    case :ets.lookup(@table_name, key) do
      [] ->
        :ok

      [{^key, attempts, first_attempt_at}] ->
        if now - first_attempt_at > @window_seconds do
          # Window has expired
          :ok
        else
          if attempts >= @max_attempts do
            {:error, :rate_limited}
          else
            :ok
          end
        end
    end
  end

  @doc """
  Records a failed validation attempt for an IP address.
  Uses atomic increment to prevent race conditions.

  Note: Prefer using `check_and_record/1` which atomically checks and records
  the attempt in a single operation.
  """
  def record_failed_attempt(ip_address) when is_binary(ip_address) do
    key = rate_limit_key(ip_address)
    now = System.system_time(:second)

    try do
      # Atomically increment the counter
      :ets.update_counter(@table_name, key, {2, 1})

      # Check if we need to reset the window
      case :ets.lookup(@table_name, key) do
        [{^key, _count, first_attempt_at}] when now - first_attempt_at > @window_seconds ->
          # Window expired, reset
          :ets.insert(@table_name, {key, 1, now})

        _ ->
          :ok
      end
    catch
      # Key doesn't exist, insert new entry
      :error, :badarg ->
        :ets.insert_new(@table_name, {key, 1, now})
    end

    :ok
  end

  @doc """
  Resets the rate limit for an IP address (e.g., after successful validation).
  """
  def reset_rate_limit(ip_address) when is_binary(ip_address) do
    key = rate_limit_key(ip_address)
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Cleans up expired entries from the rate limiter table.
  """
  def cleanup_expired do
    now = System.system_time(:second)

    :ets.foldl(
      fn {key, _attempts, first_attempt_at}, acc ->
        if now - first_attempt_at > @window_seconds do
          :ets.delete(@table_name, key)
        end

        acc
      end,
      nil,
      @table_name
    )

    :ok
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for storing rate limit data
    :ets.new(@table_name, [:named_table, :public, :set])

    # Schedule periodic cleanup every 10 minutes
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp rate_limit_key(ip_address) do
    "claim_validation:#{ip_address}"
  end

  defp schedule_cleanup do
    # Schedule cleanup every 10 minutes
    Process.send_after(self(), :cleanup, :timer.minutes(10))
  end
end
