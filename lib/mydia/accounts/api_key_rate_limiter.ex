defmodule Mydia.Accounts.ApiKeyRateLimiter do
  @moduledoc """
  Rate limiter for API key validation attempts.
  Limits failed validation attempts per IP address to prevent brute force attacks.
  """
  use GenServer

  @table_name :api_key_rate_limiter
  @max_attempts 10
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
  Checks if a key (bucket) is allowed to attempt validation.
  Returns :ok if allowed, {:error, :rate_limited} if not.

  `key` is an opaque bucket identifier, not necessarily a literal IP address --
  callers namespace it themselves (e.g. `"login_ip:\#{ip}"`,
  `"login_username:\#{username}"`) so unrelated features tracked through this
  same limiter never collide.

  ## Options

    * `:max_attempts` - defaults to #{@max_attempts}
    * `:window_seconds` - defaults to #{@window_seconds}
  """
  def check_rate_limit(key, opts \\ []) when is_binary(key) do
    max_attempts = Keyword.get(opts, :max_attempts, @max_attempts)
    window_seconds = Keyword.get(opts, :window_seconds, @window_seconds)
    storage_key = rate_limit_key(key)
    now = System.system_time(:second)

    case :ets.lookup(@table_name, storage_key) do
      [] ->
        :ok

      [{^storage_key, attempts, first_attempt_at, _window_seconds}] ->
        if now - first_attempt_at > window_seconds do
          # Window has expired, reset
          :ets.delete(@table_name, storage_key)
          :ok
        else
          if attempts >= max_attempts do
            {:error, :rate_limited}
          else
            :ok
          end
        end
    end
  end

  @doc """
  Records a failed validation attempt for a key (bucket).

  Accepts the same `:window_seconds` option as `check_rate_limit/2`, so a
  caller using a custom window keeps the same window on both the check and
  the record.

  The counter is bumped with `:ets.update_counter/4` rather than a
  lookup-then-insert pair, because a lookup-then-insert loses increments under
  concurrency: two simultaneous failed logins for the same bucket both read the
  same `attempts` and both write back that value plus one, so two guesses count
  as one. That is the wrong direction to be wrong in for a brute-force limit --
  an attacker who simply fires their guesses in parallel gets more than
  `:max_attempts` of them through. `:ets.update_counter/4` applies its whole op
  list as one atomic operation and inserts the default tuple first if the bucket
  is absent, so every concurrent caller's attempt is counted exactly once.
  """
  def record_failed_attempt(key, opts \\ []) when is_binary(key) do
    window_seconds = Keyword.get(opts, :window_seconds, @window_seconds)
    storage_key = rate_limit_key(key)
    now = System.system_time(:second)

    # `{3, 0}` adds zero to `first_attempt_at`: a read of it in the same atomic
    # operation as the increment, so the window check below cannot be decided
    # against a bucket some other caller has since reset.
    [_attempts, first_attempt_at] =
      :ets.update_counter(
        @table_name,
        storage_key,
        [{2, 1}, {3, 0}],
        {storage_key, 0, now, window_seconds}
      )

    if now - first_attempt_at > window_seconds do
      # The window elapsed, so restart it at this attempt. Guarded on the expired
      # `first_attempt_at` still being the stored one, so when several callers
      # observe the same expiry only the first replaces the bucket and the rest
      # leave that fresh bucket alone rather than each resetting it back to 1.
      :ets.select_replace(@table_name, [
        {{storage_key, :_, first_attempt_at, :_}, [],
         [{{{:const, storage_key}, 1, now, window_seconds}}]}
      ])
    end

    :ok
  end

  @doc """
  Resets the rate limit for a key (bucket) (e.g., after successful validation).
  """
  def reset_rate_limit(key) when is_binary(key) do
    storage_key = rate_limit_key(key)
    :ets.delete(@table_name, storage_key)
    :ok
  end

  @doc """
  Cleans up expired entries from the rate limiter table.

  Each bucket carries the `:window_seconds` it was recorded with (see
  `record_failed_attempt/2`), so this uses that per-bucket value rather than
  the module default `@window_seconds`. A bucket recorded with a longer
  custom window (e.g. `window_seconds: 7200`) would otherwise be cleared by
  this sweep before its own window elapsed, letting a caller back in before
  the configured lockout actually expired.
  """
  def cleanup_expired do
    now = System.system_time(:second)

    :ets.foldl(
      fn {key, _attempts, first_attempt_at, window_seconds}, acc ->
        if now - first_attempt_at > window_seconds do
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
    "api_key_validation:#{ip_address}"
  end

  defp schedule_cleanup do
    # Schedule cleanup every 10 minutes
    Process.send_after(self(), :cleanup, :timer.minutes(10))
  end
end
