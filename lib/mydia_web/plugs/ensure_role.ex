defmodule MydiaWeb.Plugs.EnsureRole do
  @moduledoc """
  Ensures that the authenticated user has the required role.

  Roles are hierarchical:
  - admin: Full access (can do everything)
  - user: Normal user access (can manage own content)
  - readonly: Read-only access (cannot modify)
  - guest: Limited access (can view and request content)

  Usage:
      plug MydiaWeb.Plugs.EnsureRole, :admin
      plug MydiaWeb.Plugs.EnsureRole, [:admin, :user]
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3, json: 2]

  alias Mydia.Auth.Guardian

  @role_hierarchy %{
    "admin" => 4,
    "user" => 3,
    "readonly" => 2,
    "guest" => 1
  }

  def init(required_roles) when is_list(required_roles), do: required_roles
  def init(required_role) when is_atom(required_role), do: [required_role]

  def call(conn, required_roles) do
    user = Guardian.Plug.current_resource(conn)

    if user && !media_token_derived?(conn) && has_required_role?(user.role, required_roles) do
      conn
    else
      handle_unauthorized(conn)
    end
  end

  # A media token proves only "this device may fetch media," not "this
  # request speaks for the user with their full privileges" -- it is a
  # 24-hour, URL-exposed credential every paired device holds, minted with
  # no narrower permission tier in practice. Guardian.Plug.current_resource/1
  # cannot distinguish that from a real session or API key on its own (both
  # ultimately resolve to the same %User{}), so MydiaWeb.Plugs.MediaAuth
  # tags the connection explicitly when it is the one that authenticated the
  # request. No route currently reaches this plug with a media token (see
  # the :api_auth pipeline comment in the router), but this refusal does not
  # depend on that staying true (T-108).
  defp media_token_derived?(conn), do: conn.assigns[:media_token_auth] == true

  defp has_required_role?(user_role, required_roles) do
    user_level = Map.get(@role_hierarchy, user_role, 0)

    Enum.any?(required_roles, fn required_role ->
      required_level = Map.get(@role_hierarchy, to_string(required_role), 999)
      user_level >= required_level
    end)
  end

  defp handle_unauthorized(conn) do
    case get_format(conn) do
      "json" ->
        conn
        |> put_status(403)
        |> json(%{
          error: "Forbidden",
          message: "You do not have permission to access this resource"
        })
        |> halt()

      _ ->
        conn
        |> put_flash(:error, "You do not have permission to access this page")
        |> redirect(to: "/")
        |> halt()
    end
  end

  defp get_format(conn) do
    case conn.path_info do
      ["api" | _] ->
        "json"

      _ ->
        case get_req_header(conn, "accept") do
          [accept | _] ->
            if String.contains?(accept, "application/json"), do: "json", else: "html"

          _ ->
            "html"
        end
    end
  end
end
