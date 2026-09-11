defmodule MydiaWeb.Plugs.LibraryApiContext do
  @moduledoc """
  Builds the Absinthe context for Library API requests.

  Runs after `MydiaWeb.Plugs.LibraryApiAuth`, so a request without a principal
  never reaches a resolver. Resolvers read `context[:principal]`; `remote_ip` is
  carried alongside for anything that later needs to rate limit per caller.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Absinthe.Plug.put_options(conn,
      context: %{
        principal: conn.assigns[:library_api_principal],
        remote_ip: format_ip(conn.remote_ip)
      }
    )
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(_), do: "unknown"
end
