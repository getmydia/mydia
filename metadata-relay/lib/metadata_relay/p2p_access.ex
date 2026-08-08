defmodule MetadataRelay.P2pAccess do
  @moduledoc """
  Access control policy for the self-hosted iroh relay.

  The relay POSTs to `/p2p/access` before accepting an endpoint. The endpoint
  ID it sends is proven by the relay handshake, so it is a trustworthy
  identifier and needs no further authentication from the client.

  This does not verify that a caller is a genuine Mydia instance. Mydia is open
  source and self-hosted with no user accounts, so there is no per-user secret
  to check. What this provides is attribution, a size-capped record of who used
  the relay, and the ability to revoke a specific endpoint.

  Phase 1 policy: allow everyone except explicitly blocked endpoints.
  """

  alias MetadataRelay.P2pAccess.Store

  @endpoint_id_length 64

  @doc """
  The authorization decision for an endpoint. ETS only.

  Case-normalizes the endpoint ID before recording the sighting and checking
  the blocklist, since `block/2` and `unblock/1` store and match on the
  downcased form and a block must not be bypassable by changing case. This
  does **not** validate the ID: malformed input is still recorded and
  checked (and will simply never match a block). Callers handling untrusted
  input who need to distinguish a malformed ID from a denied one should call
  `normalize_endpoint_id/1` first.
  """
  def authorize(endpoint_id) when is_binary(endpoint_id) do
    endpoint_id = String.downcase(endpoint_id)

    Store.record_sighting(endpoint_id)

    if Store.blocked?(endpoint_id) do
      MetadataRelay.Metrics.inc("metadata_relay_p2p_access_total", result: "deny")
      :deny
    else
      MetadataRelay.Metrics.inc("metadata_relay_p2p_access_total", result: "allow")
      :allow
    end
  end

  @doc """
  Validates and downcases an endpoint ID.

  iroh endpoint IDs are 32-byte ed25519 public keys, hex-encoded to 64
  characters.
  """
  def normalize_endpoint_id(endpoint_id) when is_binary(endpoint_id) do
    normalized = String.downcase(endpoint_id)

    if String.length(normalized) == @endpoint_id_length and
         String.match?(normalized, ~r/\A[0-9a-f]+\z/) do
      {:ok, normalized}
    else
      :error
    end
  end

  def normalize_endpoint_id(_), do: :error

  @doc """
  Whether a bearer token presented by the relay is one we accept.

  The configured value is a list so a token can be rotated by deploying both
  the old and new value before removing the old one. An empty list rejects
  everything, which fails closed if the deployment forgets the secret.
  """
  def valid_bearer?(token) when is_binary(token) do
    Enum.any?(bearer_tokens(), fn configured ->
      Plug.Crypto.secure_compare(configured, token)
    end)
  end

  def valid_bearer?(_), do: false

  @doc """
  Denies an endpoint relay access. Callable over rpc.

      MetadataRelay.P2pAccess.block("abcd...", "bandwidth abuse")
  """
  def block(endpoint_id, reason) when is_binary(reason) do
    case normalize_endpoint_id(endpoint_id) do
      {:ok, normalized} -> Store.put_block(normalized, reason)
      :error -> {:error, :invalid_endpoint_id}
    end
  end

  @doc """
  Restores relay access for an endpoint. Callable over rpc.
  """
  def unblock(endpoint_id) do
    case normalize_endpoint_id(endpoint_id) do
      {:ok, normalized} -> Store.delete_block(normalized)
      :error -> {:error, :invalid_endpoint_id}
    end
  end

  @doc """
  The most recently active endpoints, newest first. Callable over rpc.

  ETS only, deliberately: this is what an operator reaches for mid-incident,
  and it must not depend on the database being responsive. It still survives a
  restart, because `Store.seed_sightings/0` repopulates ETS from the durable
  table at boot.
  """
  def list_recent(limit \\ 50) when is_integer(limit) and limit > 0 do
    :p2p_sightings
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_id, _first, last_seen, _count} -> last_seen end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {endpoint_id, first_seen, last_seen, conn_count} ->
      %{
        endpoint_id: endpoint_id,
        first_seen: DateTime.from_unix!(first_seen),
        last_seen: DateTime.from_unix!(last_seen),
        conn_count: conn_count,
        blocked: Store.blocked?(endpoint_id)
      }
    end)
  end

  defp bearer_tokens do
    Application.get_env(:metadata_relay, :p2p_access_bearer_tokens, [])
  end
end
