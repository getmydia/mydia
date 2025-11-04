defmodule MydiaWeb.Plugs.EnsureRole do
  @moduledoc """
  Ensures that the authenticated user has the required role.

  Roles are hierarchical:
  - admin: Full access (can do everything)
  - user: Normal user access (can manage own content)
  - readonly: Read-only access (cannot modify)

  Usage:
      plug MydiaWeb.Plugs.EnsureRole, :admin
      plug MydiaWeb.Plugs.EnsureRole, [:admin, :user]
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3, json: 2]

  alias Mydia.Auth.Guardian

  @role_hierarchy %{
    "admin" => 3,
    "user" => 2,
    "readonly" => 1
  }

  def init(required_roles) when is_list(required_roles), do: required_roles
  def init(required_role) when is_atom(required_role), do: [required_role]

  def call(conn, required_roles) do
    user = Guardian.Plug.current_resource(conn)

    if user && has_required_role?(user.role, required_roles) do
      conn
    else
      handle_unauthorized(conn)
    end
  end

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
