defmodule MydiaWeb.Plugs.GridDensityCookie do
  @moduledoc """
  Copies the browser's `mydia_grid_density` cookie into the session.

  Grid density is a per-browser setting, not an account preference: a
  desktop's Dense must never reach the same account's phone (#700). The
  browser owns the value in a cookie, written by the `GridDensity` JS hook
  once the server accepts a toggle click. Reading it here, on the HTTP
  request, means the LiveView's first render already has the right column
  count instead of rendering the default and jumping on connect.

  An unknown value is ignored, so a cookie written by a different version of
  the app falls back to the default.
  """
  @behaviour Plug

  import Plug.Conn

  alias MydiaWeb.GridDensityComponents

  @cookie "mydia_grid_density"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    value = conn.cookies[@cookie]

    if GridDensityComponents.valid?(value) do
      put_session(conn, :grid_density, value)
    else
      conn
    end
  end
end
