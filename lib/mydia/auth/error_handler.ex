defmodule Mydia.Auth.ErrorHandler do
  @moduledoc """
  Handles authentication errors from Guardian.

  Provides error responses for failed authentication attempts,
  including invalid tokens, expired tokens, and missing credentials.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2, redirect: 2, put_flash: 3]

  @behaviour Guardian.Plug.ErrorHandler

  @doc """
  Handles various authentication errors.

  For API requests (JSON), returns error JSON responses.
  For browser requests (HTML), redirects to login page.
  """
  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, _reason}, _opts) do
    case get_format(conn) do
      "json" -> handle_api_error(conn, type)
      _ -> handle_browser_error(conn, type)
    end
  end

  # Handle API authentication errors
  defp handle_api_error(conn, type) do
    message = error_message(type)

    conn
    |> put_status(401)
    |> json(%{error: "Unauthorized", message: message})
  end

  # Handle browser authentication errors
  defp handle_browser_error(conn, type) do
    message = error_message(type)

    conn
    |> put_flash(:error, message)
    |> redirect(to: "/auth/login")
  end

  # Generate user-friendly error messages
  defp error_message(:invalid_token), do: "Invalid authentication token"
  defp error_message(:token_expired), do: "Your session has expired. Please log in again"
  defp error_message(:no_resource_found), do: "User not found"
  defp error_message(:unauthenticated), do: "You must be logged in to access this page"
  defp error_message(:unauthorized), do: "You are not authorized to access this resource"
  defp error_message(_), do: "Authentication failed"

  # Determine request format from accept header or path extension
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
