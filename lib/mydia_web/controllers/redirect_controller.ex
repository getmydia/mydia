defmodule MydiaWeb.RedirectController do
  use MydiaWeb, :controller

  alias MydiaWeb.AdminNav

  # `?tab=` values from when every admin page was one tabbed LiveView at
  # /admin/config. Old bookmarks still carry them.
  @legacy_config_tabs %{
    "clients" => :clients,
    "indexers" => :indexers,
    "quality" => :quality,
    "library" => :library_paths,
    "media_servers" => :media_servers,
    "remote_access" => :remote_access,
    "general" => :settings
  }

  @doc """
  Redirects /admin to the Status page.
  """
  def admin(conn, _params), do: moved_permanently(conn, ~p"/admin/status")

  @doc """
  Redirects the `/admin/config` URLs admin pages had before they moved to flat
  `/admin/<slug>` paths.

  `/admin/config/<slug>` goes to `/admin/<slug>` only when that is a page in
  `MydiaWeb.AdminNav`, and is a 404 otherwise, so the target is always a known
  page. Bare `/admin/config` goes to the page its legacy `?tab=` named, or to
  Quality.
  """
  def legacy_admin_config(conn, %{"slug" => [_ | _] = slug}) do
    case AdminNav.page_for_path("/admin/" <> Enum.join(slug, "/")) do
      nil -> not_found(conn)
      page -> moved_permanently(conn, page.path)
    end
  end

  def legacy_admin_config(conn, params) do
    path =
      case Map.fetch(@legacy_config_tabs, params["tab"]) do
        {:ok, key} -> AdminNav.fetch!(key).path
        :error -> ~p"/admin/quality"
      end

    moved_permanently(conn, path)
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

  defp moved_permanently(conn, path) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: path)
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: MydiaWeb.ErrorHTML)
    |> render(:"404")
  end
end
