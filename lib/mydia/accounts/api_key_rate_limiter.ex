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
  """
  def record_failed_attempt(key, opts \\ []) when is_binary(key) do
    window_seconds = Keyword.get(opts, :window_seconds, @window_seconds)
    storage_key = rate_limit_key(key)
    now = System.system_time(:second)

    case :ets.lookup(@table_name, storage_key) do
      [] ->
        :ets.insert(@table_name, {storage_key, 1, now, window_seconds})

      [{^storage_key, attempts, first_attempt_at, _window_seconds}] ->
        if now - first_attempt_at > window_seconds do
          # Window has expired, reset counter
          :ets.insert(@table_name, {storage_key, 1, now, window_seconds})
        else
          :ets.insert(@table_name, {storage_key, attempts + 1, first_attempt_at, window_seconds})
        end
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
