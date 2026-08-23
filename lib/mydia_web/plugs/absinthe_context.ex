defmodule MydiaWeb.Plugs.AbsintheContext do
  @moduledoc """
  Builds the Absinthe context for GraphQL requests.

  Extracts the current user from Guardian and adds it to the Absinthe context.
  This allows resolvers to access the authenticated user via `context[:current_user]`.
  """
  @behaviour Plug

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

    case Guardian.Plug.current_resource(conn) do
      nil ->
        base

      user ->
        base
        |> Map.put(:current_user, user)
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

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(_), do: "unknown"
end
