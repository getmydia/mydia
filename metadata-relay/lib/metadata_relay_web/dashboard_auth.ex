defmodule MetadataRelayWeb.DashboardAuth do
  @moduledoc """
  Access control for the maintainer dashboards.

  Two mutually exclusive modes. When `:dashboard_github_users` is non-empty the
  dashboards require GitHub sign-in and basic auth is off. When it is empty the
  relay keeps the original HTTP Basic Auth, which is what self-hosted relays,
  local development, and the test suite use.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Phoenix.Component
  alias Phoenix.LiveView

  @default_return_to "/feedback"

  @doc "Which access-control mode is active."
  def mode do
    case allowlist() do
      [] -> :basic
      _ -> :github
    end
  end

  @doc "Whether a GitHub login may reach the dashboards."
  def allowed?(login) when is_binary(login) do
    normalized = login |> String.trim() |> String.downcase()

    normalized != "" and normalized in allowlist()
  end

  def allowed?(_), do: false

  @doc """
  Constrains a stored return path to a local absolute path.

  Anything that could send the browser to another origin falls back to the
  dashboard root.
  """
  def safe_return_to("/" <> rest = path) do
    cond do
      String.starts_with?(rest, "/") -> @default_return_to
      String.starts_with?(rest, "\\") -> @default_return_to
      true -> path
    end
  end

  def safe_return_to(_), do: @default_return_to

  @doc """
  Router plug. Enforces whichever mode is active.
  """
  def require_dashboard_auth(conn, _opts) do
    case mode() do
      :basic -> basic_auth(conn)
      :github -> github_auth(conn)
    end
  end

  @doc """
  LiveView hook. The connected mount is a separate request, so the plug alone
  is not enough.
  """
  def on_mount(:require_github_login, _params, session, socket) do
    case mode() do
      :basic ->
        {:cont, assign_identity(socket, nil, nil)}

      :github ->
        login = session["github_login"]

        if allowed?(login) do
          {:cont, assign_identity(socket, login, session["github_token"])}
        else
          {:halt, LiveView.redirect(socket, to: "/auth/login")}
        end
    end
  end

  @doc """
  Values handed from the connection session to the LiveView session.
  """
  def live_session_data(conn) do
    %{
      "github_login" => get_session(conn, :github_login),
      "github_token" => get_session(conn, :github_token)
    }
  end

  defp assign_identity(socket, login, token) do
    socket
    |> Component.assign(:github_login, login)
    |> Component.assign(:github_token, token)
  end

  defp basic_auth(conn) do
    Plug.BasicAuth.basic_auth(
      conn,
      Keyword.merge(
        [realm: "Metadata Relay Dashboard"],
        Application.fetch_env!(:metadata_relay, :dashboard_auth)
      )
    )
  end

  defp github_auth(conn) do
    if allowed?(get_session(conn, :github_login)) do
      conn
    else
      conn
      |> put_session(:return_to, current_path(conn))
      |> redirect(to: "/auth/login")
      |> halt()
    end
  end

  defp current_path(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp current_path(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query

  defp allowlist do
    :metadata_relay
    |> Application.get_env(:dashboard_github_users, [])
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end
end
