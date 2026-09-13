defmodule MydiaWeb.RedirectController do
  use MydiaWeb, :controller

  @doc """
  Redirects /admin to the Status page.
  """
  def admin(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: ~p"/admin/status")
  end

  @doc """
  Redirects /preferences to /profile (preferences are now merged into profile).
  """
  def profile(conn, _params) do
    redirect(conn, to: ~p"/profile")
  end

  @doc """
  Redirects /admin/devices to /devices (pairing is a user action, not an admin one).
  """
  def devices(conn, _params) do
    redirect(conn, to: ~p"/devices")
  end
end
