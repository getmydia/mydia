defmodule MydiaWeb.PlayerHooks do
  @moduledoc """
  `on_mount` gate for the player's LiveViews.

  Router plugs do not run on live navigation inside a `live_session`, so the
  `:player` pipeline cannot guard a page reached by `navigate`. This hook
  redirects to `/` with a flash when the player is off
  (`Mydia.Player.enabled?/0`). It runs on the dead render and on the connected
  mount.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  def on_mount(:require_player, _params, _session, socket) do
    if Mydia.Player.enabled?() do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "The player is disabled on this server.")
       |> redirect(to: "/")}
    end
  end
end
