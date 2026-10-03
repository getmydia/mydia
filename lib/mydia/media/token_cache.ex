defmodule Mydia.Media.TokenCache do
  @moduledoc """
  ETS-based cache for validated media tokens.

  Provides O(1) lookups for validated JWT media tokens, avoiding database hits on
  every media request. Tokens are cached with a 5-minute TTL and automatic fallback
  to database validation on cache miss.

  Uses `read_concurrency: true` for optimal concurrent read performance.

  ## Usage

  Validate a token (checks cache first, falls back to DB):

      case TokenCache.validate(token) do
        {:ok, device, claims} -> # Token valid, proceed with request
        {:error, :token_expired} -> # Handle expired token
        {:error, :device_revoked} -> # Handle revoked device
      end

  ## Cache Invalidation

  The cache automatically expires entries after 5 minutes. For immediate
  invalidation (e.g., when a device is revoked), use:

      TokenCache.invalidate_for_device(device_id)
  """

  alias Mydia.RemoteAccess.MediaToken

  @table :media_token_cache
  # One row per device ever invalidated: {device_id, monotonic_time}.
  @stamps :media_token_cache_invalidations
  @ttl_ms :timer.minutes(5)

  @doc """
  Creates the ETS table. Must be called before the supervision tree starts.
  """
  def create_table do
    :ets.new(@stamps, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  @doc """
  Validates a media token, checking cache first.

  On cache hit: Returns cached device and claims (O(1))
  On cache miss: Validates via JWT/DB, caches result if valid

  ## Parameters

  - `token` - The JWT media token string

  ## Returns

  - `{:ok, device, claims}` - Token is valid
  - `{:error, reason}` - Token invalid, expired, or device revoked
  """
  @spec validate(String.t()) :: {:ok, struct(), map()} | {:error, atom()}
  def validate(token) do
    # Hash the token for cache key (tokens can be long)
    cache_key = :crypto.hash(:sha256, token)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, cache_key) do
      [{^cache_key, device, claims, expires_at, started}] when expires_at > now ->
        if stale_entry?(device, started) do
          # An invalidation landed after this snapshot was taken but its
          # deletion scan missed the insert: treat as a miss.
          :ets.delete(@table, cache_key)
          validate_and_cache(token, cache_key)
        else
          {:ok, device, claims}
        end

      _ ->
        # Cache miss or expired - validate via MediaToken
        validate_and_cache(token, cache_key)
    end
  end

  @doc """
  Invalidates all cached tokens for a specific device.

  Use this when a device is revoked to immediately prevent cached tokens
  from being used.

  ## Parameters

  - `device_id` - The device ID to invalidate

  ## Returns

  `:ok`
  """
  @spec invalidate_for_device(String.t()) :: :ok
  def invalidate_for_device(device_id) do
    # Stamp first so a validation that read the old snapshot and has not yet
    # stored it will see the stamp and skip the insert (see validate_and_cache/2).
    :ets.insert(@stamps, {device_id, System.monotonic_time()})

    # Scan and delete all entries for this device
    # This is O(n) but should be rare (only on device revocation)
    :ets.foldl(
      fn {key, device, _claims, _expires_at, _started}, acc ->
        if device.id == device_id do
          :ets.delete(@table, key)
        end

        acc
      end,
      :ok,
      @table
    )

    :ok
  end

  @doc """
  Clears all entries from the cache.

  Useful for testing or emergency cache invalidation.

  ## Returns

  `:ok`
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@stamps)
    :ok
  end

  @doc """
  Returns the number of cached tokens.

  ## Returns

  The cache entry count
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  # Private functions

  defp validate_and_cache(token, cache_key) do
    # Race: verify_token reads the device and user from the database, and the
    # insert happens afterwards. An invalidation landing in between would be
    # undone by inserting the stale snapshot. Capture the time before the read
    # and let store_if_current/4 refuse the insert if a stamp is not older.
    started = System.monotonic_time()

    case MediaToken.verify_token(token) do
      {:ok, device, claims} ->
        finish_validation(token, cache_key, device, claims, started)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale_entry?(device, started) do
    case :ets.lookup(@stamps, device.id) do
      [{_id, stamped_at}] -> stamped_at >= started
      _ -> false
    end
  end

  @doc false
  # Attempts to cache the verified token, but if a concurrent invalidation raced
  # the verification, re-verifies instead of returning a stale device/claims.
  def finish_validation(token, cache_key, device, claims, started) do
    case store_if_current(cache_key, device, claims, started) do
      :ok ->
        {:ok, device, claims}

      :skipped ->
        # Device was invalidated after verification began; the snapshot is stale.
        # Re-verify to get the current state.
        MediaToken.verify_token(token)
    end
  end

  @doc false
  # Caches a verified token unless its device was invalidated at or after
  # `started` (a `System.monotonic_time/0` value taken before verification).
  def store_if_current(cache_key, device, claims, started) do
    case :ets.lookup(@stamps, device.id) do
      [{_id, stamped_at}] when stamped_at >= started ->
        :skipped

      _ ->
        expires_at = System.monotonic_time(:millisecond) + @ttl_ms
        :ets.insert(@table, {cache_key, device, claims, expires_at, started})
        :ok
    end
  end
end
