defmodule MydiaWeb.Schema.Resolvers.RemoteAccessResolver do
  @moduledoc """
  Resolvers for remote access GraphQL mutations (media token management).
  """

  require Logger

  alias Mydia.Accounts.ApiKeyRateLimiter
  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.MediaToken
  alias Mydia.RemoteAccess.Pairing

  @doc """
  Generates a pairing claim code for the current user.

  The code can be used by a remote device to pair with this Mydia instance.
  Requires authentication.
  """
  def generate_claim_code(_parent, _args, %{context: %{current_user: user}}) do
    case RemoteAccess.generate_claim_code(user.id) do
      {:ok, claim} ->
        {:ok,
         %{
           code: claim.code,
           expires_at: claim.expires_at,
           relay_registered: claim.relay_registered
         }}

      {:error, :relay_not_connected} ->
        {:error, "Relay service is not connected"}

      {:error, :relay_timeout} ->
        {:error, "Relay service did not respond in time"}

      {:error, {:relay_error, _reason}} ->
        {:error, "Relay service error"}

      {:error, _changeset} ->
        {:error, "Failed to generate claim code"}
    end
  end

  def generate_claim_code(_parent, _args, _context) do
    {:error, "Authentication required"}
  end

  @doc """
  Returns the current remote access / P2P connection status.
  Requires authentication.
  """
  def status(_parent, _args, %{context: %{current_user: _user}}) do
    case RemoteAccess.p2p_status() do
      {:ok, %{running: true} = s} ->
        {:ok,
         %{
           enabled: true,
           endpoint_addr: s.node_addr,
           connected_peers: s.connected_peers
         }}

      _ ->
        {:ok, %{enabled: false, endpoint_addr: nil, connected_peers: 0}}
    end
  end

  def status(_parent, _args, _context) do
    {:error, "Authentication required"}
  end

  def refresh_media_token(_parent, %{token: token}, _context) do
    case MediaToken.refresh_token(token) do
      {:ok, new_token, claims} ->
        expires_at = DateTime.from_unix!(claims["exp"])
        permissions = Map.get(claims, "permissions", [])

        {:ok,
         %{
           token: new_token,
           expires_at: expires_at,
           permissions: permissions
         }}

      {:error, :token_expired} ->
        {:error, "Token has expired"}

      {:error, :invalid_token} ->
        {:error, "Invalid token"}

      {:error, :device_not_found} ->
        {:error, "Device not found"}

      {:error, :device_revoked} ->
        {:error, "Device has been revoked"}

      {:error, reason} ->
        {:error, "Failed to refresh token: #{inspect(reason)}"}
    end
  end

  @doc """
  Exchanges a long-lived pairing device token for a fresh access token.

  Access tokens expire after the configured Guardian TTL while the device pairing
  itself does not, so without this a paired player silently drops to unauthenticated
  once its token ages out and has to be re-paired by hand. Deliberately requires no
  authentication: the device token is the proof of identity, the same way
  `refresh_media_token/3` trusts the media token.
  """
  def refresh_access_token(_parent, %{device_token: device_token}, %{context: context}) do
    bucket = rate_limit_bucket(context)

    case ApiKeyRateLimiter.check_rate_limit(bucket) do
      :ok -> do_refresh_access_token(device_token, bucket)
      {:error, :rate_limited} -> {:error, "Too many refresh attempts, try again later"}
    end
  end

  # Device tokens are Argon2 hashed with a per-row salt, so verification has to
  # try every non-revoked device: a wrong token costs one full Argon2 pass per
  # paired device (~70ms each). Left unbounded on an unauthenticated mutation
  # that is a CPU amplification vector, so failures are rate limited per caller
  # exactly as ApiAuth does for API key validation. Successful refreshes never
  # count against the limit.
  defp do_refresh_access_token(device_token, bucket) do
    with {:ok, device} <- RemoteAccess.verify_device_token(device_token),
         {:ok, token, claims} <- Pairing.generate_access_token_with_claims(device),
         {:ok, expires_at} <- expires_at_from_claims(claims) do
      RemoteAccess.touch_device(device)

      {:ok, %{token: token, expires_at: expires_at}}
    else
      {:error, :not_found} ->
        ApiKeyRateLimiter.record_failed_attempt(bucket)
        {:error, "Invalid or revoked device token"}

      {:error, reason} ->
        Logger.warning("Failed to refresh access token: #{inspect(reason)}")
        ApiKeyRateLimiter.record_failed_attempt(bucket)
        {:error, "Failed to refresh access token"}
    end
  end

  # Reported rather than raised: this mutation is public, so a surprising claim
  # set must not crash the request.
  defp expires_at_from_claims(%{"exp" => exp}) when is_integer(exp), do: DateTime.from_unix(exp)
  defp expires_at_from_claims(_), do: {:error, :missing_expiry}

  # P2P callers have no IP, but reaching that transport already requires an
  # established QUIC session with the node, so they share one bucket.
  defp rate_limit_bucket(context) do
    case context[:remote_ip] do
      ip when is_binary(ip) -> "refresh_access_token:#{ip}"
      _ -> "refresh_access_token:#{context[:source] || :unknown}"
    end
  end
end
