defmodule MydiaWeb.Plugs.EnsureAuthenticated do
  @moduledoc """
  Ensures that a user is authenticated before accessing a resource.

  If the user is not authenticated, they will be redirected to the login page
  or receive a 401 error for API requests.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3, json: 2]

  alias Mydia.Auth.Guardian

  def init(opts), do: opts

  def call(conn, _opts) do
    case Guardian.Plug.current_resource(conn) do
      nil ->
        handle_unauthenticated(conn)

      _user ->
        conn
    end
  end

  defp handle_unauthenticated(conn) do
    case get_format(conn) do
      "json" ->
        conn
        |> put_status(401)
        |> json(%{
          error: "Unauthorized",
          message: "You must be logged in to access this resource"
        })
        |> halt()

      _ ->
        conn
        |> put_flash(:error, "You must be logged in to access this page")
        |> redirect(to: "/auth/login")
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
