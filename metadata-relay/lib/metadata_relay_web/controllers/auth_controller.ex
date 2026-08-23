defmodule MetadataRelayWeb.AuthController do
  @moduledoc """
  GitHub App sign-in for the maintainer dashboards.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias MetadataRelay.GitHub.OAuth
  alias MetadataRelayWeb.DashboardAuth

  @generic_failure "GitHub sign-in failed. Try again."
  @not_authorized "That GitHub account is not an active member of the organization."
  @unavailable "GitHub could not confirm your membership right now. Try again."

  def login(conn, params) do
    render(conn, :login, error: error_message(params["error"]))
  end

  def request(conn, _params) do
    if OAuth.configured?() do
      state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      conn
      |> put_session(:oauth_state, state)
      |> redirect(external: OAuth.authorize_url(state))
    else
      redirect(conn, to: "/auth/login?error=failed")
    end
  end

  # Nested query params (`?state[]=x`) arrive as lists, and both
  # `secure_compare/2` and `exchange_code/1` only accept binaries. Guarding here
  # sends malformed callbacks to the catch-all clause below instead of raising.
  def callback(conn, %{"code" => code, "state" => state})
      when is_binary(code) and is_binary(state) do
    expected = get_session(conn, :oauth_state)

    with true <- is_binary(expected) and Plug.Crypto.secure_compare(state, expected),
         {:ok, token} <- OAuth.exchange_code(code),
         {:ok, %{login: login}} <- OAuth.fetch_user(token) do
      case DashboardAuth.verify_membership(token) do
        :ok -> sign_in(conn, login, token)
        {:error, :denied} -> deny(conn, "denied")
        {:error, :unavailable} -> deny(conn, "unavailable")
      end
    else
      _ -> deny(conn, "failed")
    end
  end

  def callback(conn, _params), do: deny(conn, "failed")

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> redirect(to: "/auth/login")
  end

  defp sign_in(conn, login, token) do
    return_to = DashboardAuth.safe_return_to(get_session(conn, :return_to))

    conn
    |> configure_session(renew: true)
    # The state has served its purpose. Dropping it makes it single-use, so a
    # replayed callback URL cannot be validated against a stale value.
    |> delete_session(:oauth_state)
    |> delete_session(:return_to)
    |> put_session(:github_login, login)
    |> put_session(:github_token, token)
    |> put_session(:github_verified_at, DashboardAuth.verified_now())
    |> redirect(to: return_to)
  end

  defp deny(conn, reason) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> redirect(to: "/auth/login?error=" <> reason)
  end

  defp error_message("denied"), do: @not_authorized
  defp error_message("unavailable"), do: @unavailable
  defp error_message("failed"), do: @generic_failure
  defp error_message(_), do: nil
end
