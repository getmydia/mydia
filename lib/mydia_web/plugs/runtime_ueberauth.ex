defmodule MydiaWeb.Plugs.RuntimeUeberauth do
  @moduledoc """
  A wrapper plug for Ueberauth that initializes routes at runtime instead of compile time.

  This solves the issue where `plug Ueberauth` reads its configuration at compile time,
  which doesn't work with runtime.exs configuration in releases. The OIDC providers
  are configured via environment variables in runtime.exs, but the standard Ueberauth
  plug caches its routes when the controller module is compiled.

  This plug calls `Ueberauth.init/1` at runtime (during each request), ensuring it
  always has the latest configuration from runtime.exs.

  `oidcc` strategies resolve the client context via a `GenServer.call/2` to a
  provider-configuration worker that refreshes discovery metadata in the
  background. If that worker is busy against a slow or unreachable IdP, the
  call times out and the exit propagates up through Ueberauth's strategy
  pipeline, which has no exit trap of its own. Left unguarded, that turns a
  slow identity provider into a 500 instead of the login-failure redirect
  `MydiaWeb.AuthController` already implements, so it is caught here and
  routed to the same fallback.
  """

  @behaviour Plug

  require Logger

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Initialize Ueberauth routes at runtime, reading current config
    routes = Ueberauth.init([])

    # Call Ueberauth with the runtime-initialized routes
    Ueberauth.call(conn, routes)
  catch
    :exit, reason ->
      Logger.error("Ueberauth request exited: #{inspect(reason)}")

      conn
      |> put_flash(:error, "The identity provider did not respond in time. Please try again.")
      |> redirect(to: "/auth/login")
      |> Plug.Conn.halt()
  end
end
