defmodule MydiaWeb.SessionController do
  @moduledoc """
  Local authentication controller.

  Provides username/password login when LOCAL_AUTH_ENABLED is true.
  Can be disabled in favor of OIDC-only authentication.
  """
  use MydiaWeb, :controller

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian
  alias Mydia.Config

  @doc """
  Renders the login form.
  """
  def new(conn, _params) do
    # Redirect to first-time setup if no users exist
    # The setup page will offer both local admin creation and OIDC login options
    if Accounts.any_users_exist?() do
      # Check if local auth is enabled
      config = Config.get()

      if config.auth.local_enabled do
        render(conn, :new,
          changeset: Accounts.change_user(%Mydia.Accounts.User{}),
          oidc_configured: oidc_configured?()
        )
      else
        conn
        |> put_flash(:error, "Local authentication is disabled")
        |> redirect(to: "/")
      end
    else
      conn
      |> redirect(to: ~p"/setup")
    end
  end

  # Check if OIDC is configured
  defp oidc_configured? do
    case Application.get_env(:ueberauth, Ueberauth) do
      nil -> false
      config -> Keyword.get(config, :providers, []) != []
    end
  end

  @doc """
  Handles local login with username and password.
  """
  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    # Check if local auth is enabled
    config = Config.get()

    if config.auth.local_enabled do
      ip_address = remote_ip(conn)

      case Accounts.check_login_rate_limit(ip_address, username) do
        :ok ->
          attempt_login(conn, ip_address, username, password)

        {:error, :rate_limited} ->
          login_error(conn, "Too many login attempts. Please try again later.")
      end
    else
      conn
      |> put_flash(:error, "Local authentication is disabled")
      |> redirect(to: "/")
    end
  end

  defp attempt_login(conn, ip_address, username, password) do
    case Accounts.get_user_by_username(username) do
      nil ->
        Accounts.record_login_failure(ip_address, username)
        login_error(conn, "Invalid username or password")

      user ->
        if Accounts.verify_password(user, password) do
          Accounts.reset_login_rate_limit(ip_address, username)
          # Update last login timestamp
          Accounts.update_last_login(user)

          # Sign in the user via Guardian, which stores the token in session
          # under the :guardian_default_token key that VerifySession expects.
          # Also store under :guardian_token for backward compatibility with
          # code that reads that key directly (e.g., logout, Flutter cookie auth).
          {:ok, token, _claims} = Guardian.create_token(user)

          conn
          |> Guardian.Plug.sign_in(user)
          |> put_session(:guardian_default_token, token)
          |> put_session(:guardian_token, token)
          |> put_flash(:info, "Successfully logged in!")
          |> redirect(to: "/")
        else
          Accounts.record_login_failure(ip_address, username)
          login_error(conn, "Invalid username or password")
        end
    end
  end

  defp login_error(conn, message) do
    conn
    |> put_flash(:error, message)
    |> render(:new,
      changeset: Accounts.change_user(%Mydia.Accounts.User{}),
      oidc_configured: oidc_configured?()
    )
  end

  defp remote_ip(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
      _ -> "unknown"
    end
  end
end
