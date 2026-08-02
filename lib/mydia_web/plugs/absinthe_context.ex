defmodule MydiaWeb.Plugs.AbsintheContext do
  @moduledoc """
  Builds the Absinthe context for GraphQL requests.

  Extracts the current user from Guardian and adds it to the Absinthe context.
  This allows resolvers to access the authenticated user via `context[:current_user]`.
  """
  @behaviour Plug

  alias Mydia.Auth.Guardian

  def init(opts), do: opts

  def call(conn, _opts) do
    context = build_context(conn)
    Absinthe.Plug.put_options(conn, context: context)
  end

  defp build_context(conn) do
    # remote_ip lets unauthenticated resolvers rate limit per caller, the same way
    # MydiaWeb.Plugs.ApiAuth does for API key validation.
    base = %{source: :http, remote_ip: format_ip(conn.remote_ip)}

    case Guardian.Plug.current_resource(conn) do
      nil -> base
      user -> Map.put(base, :current_user, user)
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(_), do: "unknown"
end
