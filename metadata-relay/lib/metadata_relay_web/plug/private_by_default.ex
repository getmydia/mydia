defmodule MetadataRelayWeb.Plug.PrivateByDefault do
  @moduledoc """
  Marks every response `private, no-store` unless something downstream
  explicitly made it `public`.

  `relay.mydia.dev` sits behind a Cloudflare Cache Rule that makes the whole
  host eligible for caching and follows the origin's `Cache-Control`. The only
  responses that may be shared between installs are the ones
  `MetadataRelay.Plug.Cache` and the `/client-config` route mark `public`.
  Everything else (pairing, crash reports, feedback, the maintainer
  dashboards, errors from any route) must stay out of the shared cache, and
  this plug makes that the default instead of something each route has to
  remember.

  It runs in the endpoint rather than the API router because the dashboards
  are Phoenix routes that never reach `MetadataRelay.Router`. Its
  `before_send` callback is registered before any route's, and Plug runs
  those callbacks in reverse registration order, so it sees the final header.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: register_before_send(conn, &mark_private/1)

  defp mark_private(conn) do
    case get_resp_header(conn, "cache-control") do
      ["public" <> _] -> conn
      _ -> put_resp_header(conn, "cache-control", "private, no-store")
    end
  end
end
