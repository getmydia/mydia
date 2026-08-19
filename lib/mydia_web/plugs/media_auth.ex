defmodule MydiaWeb.Plugs.MediaAuth do
  @moduledoc """
  Authenticates media requests using JWT media tokens.

  Media tokens can be provided via:
  1. Authorization header: `Authorization: Bearer <token>`
  2. Query parameter: `?token=<token>`

  If valid and the device is not revoked, the device and user are loaded
  and available via assigns.

  ## Usage

      # In a controller or pipeline
      plug MydiaWeb.Plugs.MediaAuth

      # Access the device and user
      def play(conn, _params) do
        device = conn.assigns[:media_device]
        user = conn.assigns[:media_user]
        # ...
      end

  ## Optional Permissions

  You can require specific permissions by passing them to the plug:

      plug MydiaWeb.Plugs.MediaAuth, permissions: ["stream"]
      plug MydiaWeb.Plugs.MediaAuth, permissions: ["download", "stream"]

  If permissions are required and the token doesn't have them,
  a 403 Forbidden response is returned.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Mydia.RemoteAccess.MediaToken
  alias Mydia.Media.TokenCache

  def init(opts), do: opts

  def call(conn, opts) do
    # Check if a user is already authenticated (e.g., via AuthPipeline)
    # If so, skip media token authentication
    if user_already_authenticated?(conn) do
      conn
    else
      # Check if a media token is provided
      case extract_token(conn) do
        nil ->
          # No media token provided - pass through to let other auth mechanisms work
          # or fail at EnsureAuthenticated if this is the last auth plug
          conn

        token ->
          # Media token provided - validate it
          authenticate_with_media_token(conn, token, opts)
      end
    end
  end

  defp user_already_authenticated?(conn) do
    # Check both assigns and the Guardian resource (set by AuthPipeline)
    conn.assigns[:current_user] != nil ||
      Mydia.Auth.Guardian.Plug.current_resource(conn) != nil
  end

  defp authenticate_with_media_token(conn, token, opts) do
    required_permissions = Keyword.get(opts, :permissions, [])

    # Use TokenCache for O(1) cached lookups, with DB fallback on cache miss
    case TokenCache.validate(token) do
      {:ok, device, claims} ->
        if has_required_permissions?(claims, required_permissions) do
          conn
          |> assign(:media_device, device)
          |> assign(:media_user, device.user)
          |> assign(:media_token_claims, claims)
          # Also set Guardian resource so EnsureAuthenticated passes
          |> Mydia.Auth.Guardian.Plug.put_current_resource(device.user)
        else
          forbidden(conn, "Insufficient permissions")
        end

      {:error, :token_expired} ->
        unauthorized(conn, "Token expired")

      {:error, :device_revoked} ->
        forbidden(conn, "Device access revoked")

      {:error, :device_not_found} ->
        unauthorized(conn, "Invalid device")

      {:error, _reason} ->
        unauthorized(conn, "Invalid token")
    end
  end

  defp extract_token(conn) do
    # Check Authorization header first (preferred method)
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        token

      _ ->
        # Fall back to query parameter (for URLs like HLS playlists)
        case conn.query_params do
          %{"token" => token} when is_binary(token) and token != "" -> token
          _ -> nil
        end
    end
  end

  defp has_required_permissions?(_claims, []), do: true

  defp has_required_permissions?(claims, required_permissions) do
    Enum.all?(required_permissions, fn permission ->
      MediaToken.has_permission?(claims, permission)
    end)
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(401)
    |> json(%{error: "Unauthorized", message: message})
    |> halt()
  end

  defp forbidden(conn, message) do
    conn
    |> put_status(403)
    |> json(%{error: "Forbidden", message: message})
    |> halt()
  end
end
