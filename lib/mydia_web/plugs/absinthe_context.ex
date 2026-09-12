defmodule MydiaWeb.Plugs.AbsintheContext do
  @moduledoc """
  Builds the Absinthe context for GraphQL requests.

  Extracts the current user from Guardian and adds it to the Absinthe context.
  This allows resolvers to access the authenticated user via `context[:current_user]`.
  """
  @behaviour Plug

  alias Mydia.Accounts.Scope
  alias Mydia.Auth.Guardian
  alias Mydia.RemoteAccess

  def init(opts), do: opts

  def call(conn, _opts) do
    context = build_context(conn)
    Absinthe.Plug.put_options(conn, context: context)
  end

  defp build_context(conn) do
    # remote_ip lets unauthenticated resolvers rate limit per caller, the same way
    # MydiaWeb.Plugs.ApiAuth does for API key validation.
    base =
      %{source: :http, remote_ip: format_ip(conn.remote_ip)}
      |> put_device_profile(conn.assigns[:device_profile])
      |> put_media_token_auth(conn.assigns[:media_token_auth])

    case Guardian.Plug.current_resource(conn) do
      nil ->
        base

      user ->
        base
        |> Map.put(:current_user, user)
        |> Map.put(:current_scope, Scope.for_user(user))
        |> put_device_id(Guardian.Plug.current_claims(conn))
    end
  end

  # A paired device's token carries device_id; a plain browser login does not.
  defp put_device_id(context, claims) do
    case RemoteAccess.device_id_from_claims(claims) do
      nil -> context
      device_id -> Map.put(context, :device_id, device_id)
    end
  end

  # Absent rather than nil, so a resolver can pattern match on presence and does
  # not have to distinguish "no header" from "header said nothing".
  defp put_device_profile(context, nil), do: context
  defp put_device_profile(context, profile), do: Map.put(context, :device_profile, profile)

  # Lets a resolver refuse a media-token-derived request outright (see
  # MydiaWeb.Schema.Resolvers.ApiKeyResolver.create_api_key/3). No route
  # currently mounts MediaAuth ahead of :graphql_context (see the :api_auth
  # pipeline comment in the router), so this is defense in depth against a
  # future pipeline change reintroducing that reachability, not something
  # exercised by any request today.
  defp put_media_token_auth(context, true), do: Map.put(context, :media_token_auth, true)
  defp put_media_token_auth(context, _), do: context

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(_), do: "unknown"
end
