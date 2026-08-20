defmodule MetadataRelay.Pairing do
  @moduledoc """
  Context module for iroh-based P2P pairing.

  This module handles the simplified pairing flow:
  - Creating claim codes with node_addr (iroh EndpointAddr)
  - Looking up claim codes to get node_addr
  - Deleting claim codes after successful pairing

  Claims are stored in Redis with automatic TTL expiration.
  Falls back to ETS if Redis is unavailable.
  """

  require Logger

  @key_prefix "pairing:"
  @sealed_key_prefix "pairing:v2:"
  @default_ttl_seconds 300

  # ETS table for fallback when Redis unavailable
  @ets_table :pairing_claims

  @doc """
  Creates a new claim code for a node_addr.

  ## Parameters
  - `node_addr` - JSON string of iroh EndpointAddr
  - `opts` - Options:
    - `:ttl_seconds` - Custom TTL (default: 300)
    - `:code` - Custom code (default: auto-generated)

  Returns `{:ok, claim}` or `{:error, reason}`.

  ## Example

      iex> create_claim('{"relay_url":"...","node_id":"..."}')
      {:ok, %{code: "ABC123", node_addr: "...", expires_at: ~U[...]}}
  """
  def create_claim(node_addr, opts \\ []) do
    code = Keyword.get(opts, :code, generate_code()) |> String.upcase()
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(ttl, :second)
      |> DateTime.truncate(:second)

    case store_claim(code, node_addr, ttl) do
      :ok ->
        Logger.info("Pairing claim created")
        {:ok, %{code: code, node_addr: node_addr, expires_at: expires_at}}

      {:error, reason} ->
        Logger.error("Failed to create pairing claim: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Looks up a claim code and returns the node_addr if valid.

  ## Parameters
  - `code` - The claim code to look up

  Returns `{:ok, node_addr}` or `{:error, reason}`.
  """
  def get_claim(code) do
    code = normalize_code(code)

    case fetch_claim(code) do
      {:ok, node_addr} ->
        Logger.info("Pairing claim lookup successful")
        {:ok, node_addr}

      {:error, :not_found} ->
        Logger.warning("Pairing claim lookup failed", reason: :not_found)

        {:error, :not_found}
    end
  end

  @doc """
  Deletes a claim code.

  Called after successful pairing to clean up.

  ## Parameters
  - `code` - The claim code to delete

  Returns `:ok`.
  """
  def delete_claim(code) do
    code = normalize_code(code)
    delete_stored_claim(code)

    Logger.info("Pairing claim deleted")
    :ok
  end

  @doc """
  Stores a sealed pairing claim under its blinded lookup key.

  The relay cannot read either value. `lookup_key` is derived from the claim
  code by the server, and `sealed` is an AEAD blob whose key the relay never
  sees. Expiry matches v1 at #{@default_ttl_seconds} seconds.
  """
  def store_sealed(lookup_key, sealed) do
    key = @sealed_key_prefix <> lookup_key

    case redis_conn() do
      {:ok, conn} ->
        case Redix.command(conn, ["SETEX", key, @default_ttl_seconds, sealed]) do
          {:ok, "OK"} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :not_available ->
        store_in_ets(key, sealed, @default_ttl_seconds)
    end
  end

  @doc """
  Fetches a sealed pairing claim by its blinded lookup key.
  """
  def fetch_sealed(lookup_key) do
    key = @sealed_key_prefix <> lookup_key

    case redis_conn() do
      {:ok, conn} ->
        case Redix.command(conn, ["GET", key]) do
          {:ok, nil} -> {:error, :not_found}
          {:ok, sealed} -> {:ok, sealed}
          {:error, _reason} -> {:error, :not_found}
        end

      :not_available ->
        fetch_from_ets(key)
    end
  end

  @doc """
  Deletes a sealed pairing claim. Called after a successful pairing.
  """
  def delete_sealed(lookup_key), do: delete_stored_claim_key(@sealed_key_prefix <> lookup_key)

  @doc """
  Initializes ETS table for fallback storage.
  Should be called by a long-lived process at application startup.
  """
  def init_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
      Logger.info("Created ETS table for pairing claims fallback")
    end

    :ok
  end

  @doc """
  Ensures ETS table is available for fallback storage.
  """
  def ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      {:error, :table_not_initialized}
    else
      :ok
    end
  end

  # Storage functions - try Redis first, fall back to ETS

  defp store_claim(code, node_addr, ttl_seconds) do
    key = @key_prefix <> code

    case redis_conn() do
      {:ok, conn} ->
        case Redix.command(conn, ["SETEX", key, ttl_seconds, node_addr]) do
          {:ok, "OK"} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :not_available ->
        store_in_ets(key, node_addr, ttl_seconds)
    end
  end

  defp fetch_claim(code) do
    key = @key_prefix <> code

    case redis_conn() do
      {:ok, conn} ->
        case Redix.command(conn, ["GET", key]) do
          {:ok, nil} -> {:error, :not_found}
          {:ok, node_addr} -> {:ok, node_addr}
          {:error, _reason} -> {:error, :not_found}
        end

      :not_available ->
        fetch_from_ets(key)
    end
  end

  defp delete_stored_claim(code) do
    delete_stored_claim_key(@key_prefix <> code)
  end

  defp delete_stored_claim_key(key) do
    case redis_conn() do
      {:ok, conn} -> Redix.command(conn, ["DEL", key])
      :not_available -> delete_from_ets(key)
    end

    :ok
  end

  # Redis connection helper
  defp redis_conn do
    case Process.whereis(:metadata_relay_redis) do
      nil -> :not_available
      pid -> {:ok, pid}
    end
  end

  # ETS fallback storage

  defp store_in_ets(key, value, ttl_seconds) do
    with :ok <- ensure_ets_table() do
      expires_at = System.system_time(:second) + ttl_seconds
      :ets.insert(@ets_table, {key, value, expires_at})
      :ok
    end
  end

  defp fetch_from_ets(key) do
    with :ok <- ensure_ets_table() do
      case :ets.lookup(@ets_table, key) do
        [{^key, value, expires_at}] ->
          if System.system_time(:second) < expires_at do
            {:ok, value}
          else
            # Expired - clean up
            :ets.delete(@ets_table, key)
            {:error, :not_found}
          end

        [] ->
          {:error, :not_found}
      end
    else
      {:error, :table_not_initialized} ->
        {:error, :not_found}
    end
  end

  defp delete_from_ets(key) do
    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete(@ets_table, key)
    end

    :ok
  end

  # Code generation and normalization

  @doc """
  Generates a cryptographically secure random claim code.

  Uses `:crypto.strong_rand_bytes/1` for secure random number generation.
  Default length is 6 characters providing ~31 bits of entropy.
  Excludes ambiguous characters (0, O, I, 1, L).
  """
  def generate_code(length \\ 6) do
    # Alphabet without ambiguous characters: 0/O, 1/I/L
    alphabet = ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    char_count = length(alphabet)

    :crypto.strong_rand_bytes(length)
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> Enum.at(alphabet, rem(byte, char_count)) end)
    |> List.to_string()
  end

  defp normalize_code(code) when is_binary(code) do
    code
    |> String.upcase()
    |> String.replace(~r/[-\s]/, "")
  end

  defp normalize_code(code), do: code
end
