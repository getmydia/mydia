defmodule MetadataRelayWeb.DashboardAuth do
  @moduledoc """
  Access control for the maintainer dashboards.

  Two mutually exclusive modes. When `:dashboard_github_org` is set the
  dashboards require GitHub sign-in by an active member of that organization,
  and basic auth is off. When it is unset the relay keeps the original HTTP
  Basic Auth, which is what self-hosted relays, local development, and the test
  suite use.

  Membership is a remote lookup, not a config value, so it is checked once at
  sign-in and then re-checked at most every `#{div(300, 60)}` minutes. That
  bounds how long someone removed from the organization keeps a live session,
  without an API call on every request.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias MetadataRelay.GitHub.OAuth
  alias Phoenix.Component
  alias Phoenix.LiveView

  @default_return_to "/feedback"

  # How long a verified membership is trusted before it is checked again.
  @revalidate_after_seconds 300

  @doc "Which access-control mode is active."
  def mode do
    case org() do
      nil -> :basic
      _ -> :github
    end
  end

  @doc "The organization whose members may reach the dashboards, or nil."
  def org do
    :metadata_relay
    |> Application.get_env(:dashboard_github_org)
    |> normalize()
  end

  @doc """
  Confirms the token's owner is an active member of the configured org.

  Returns `:ok`, or `{:error, :denied}` when GitHub answered definitively that
  this account may not enter, or `{:error, :unavailable}` when GitHub could not
  be reached. Callers distinguish the two: a denial ends the session, an
  outage leaves an already-verified session alone.
  """
  def verify_membership(token) do
    case org() do
      nil ->
        {:error, :denied}

      org when is_binary(token) ->
        classify(OAuth.fetch_org_membership(token, org))

      _org ->
        {:error, :denied}
    end
  end

  defp classify({:ok, :active}), do: :ok
  defp classify({:error, :not_a_member}), do: {:error, :denied}
  defp classify({:error, {:membership, _state}}), do: {:error, :denied}
  defp classify({:error, {:http, status}}) when status in 401..403, do: {:error, :denied}
  defp classify({:error, _reason}), do: {:error, :unavailable}

  @doc "Seconds-since-epoch stamp recorded when membership was last confirmed."
  def verified_now, do: System.system_time(:second)

  @doc "Whether a stored verification stamp is still inside the revalidation window."
  def verification_fresh?(verified_at) when is_integer(verified_at) do
    verified_now() - verified_at < @revalidate_after_seconds
  end

  def verification_fresh?(_), do: false

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

  The hook cannot write back to the session, so a stale stamp is re-checked on
  every mount until an ordinary request refreshes it. Mounts are infrequent
  enough for that to be cheap.
  """
  def on_mount(:require_github_login, _params, session, socket) do
    case mode() do
      :basic ->
        {:cont, assign_identity(socket, nil, nil)}

      :github ->
        login = session["github_login"]
        token = session["github_token"]

        if signed_in?(login, token) and mount_membership_ok?(token, session["github_verified_at"]) do
          {:cont, assign_identity(socket, login, token)}
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
      "github_token" => get_session(conn, :github_token),
      "github_verified_at" => get_session(conn, :github_verified_at)
    }
  end

  defp signed_in?(login, token), do: is_binary(login) and login != "" and is_binary(token)

  defp mount_membership_ok?(token, verified_at) do
    if verification_fresh?(verified_at) do
      true
    else
      # An outage must not sign a verified maintainer out mid-session.
      verify_membership(token) != {:error, :denied}
    end
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
    login = get_session(conn, :github_login)
    token = get_session(conn, :github_token)

    if signed_in?(login, token) do
      revalidate(conn, token)
    else
      send_to_login(conn)
    end
  end

  defp revalidate(conn, token) do
    if verification_fresh?(get_session(conn, :github_verified_at)) do
      conn
    else
      case verify_membership(token) do
        :ok ->
          put_session(conn, :github_verified_at, verified_now())

        {:error, :denied} ->
          conn
          |> clear_session()
          |> configure_session(drop: true)
          |> redirect(to: "/auth/login?error=denied")
          |> halt()

        # GitHub is unreachable. The session was verified at some point, so
        # keep it and try again on the next request rather than locking the
        # maintainer out of the dashboards during someone else's outage.
        {:error, :unavailable} ->
          conn
      end
    end
  end

  defp send_to_login(conn) do
    conn
    |> put_session(:return_to, current_path(conn))
    |> redirect(to: "/auth/login")
    |> halt()
  end

  defp current_path(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp current_path(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query

  defp normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize(_), do: nil
end
