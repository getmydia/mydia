defmodule MydiaWeb.Schema.Resolvers.RemoteAccessResolver do
  @moduledoc """
  Resolvers for remote access GraphQL mutations (media token management).
  """

  require Logger

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
           expires_at: claim.expires_at
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
  def refresh_access_token(_parent, %{device_token: device_token}, _context) do
    with {:ok, device} <- RemoteAccess.verify_device_token(device_token),
         {:ok, token, claims} <- Pairing.generate_access_token_with_claims(device) do
      RemoteAccess.touch_device(device)

      {:ok, %{token: token, expires_at: DateTime.from_unix!(claims["exp"])}}
    else
      {:error, :not_found} ->
        {:error, "Invalid or revoked device token"}

      {:error, reason} ->
        Logger.warning("Failed to refresh access token: #{inspect(reason)}")
        {:error, "Failed to refresh access token"}
    end
  end
end
