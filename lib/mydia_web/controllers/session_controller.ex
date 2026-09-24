defmodule MydiaWeb.SessionController do
  @moduledoc """
  Local authentication controller.

  Provides username/password login when LOCAL_AUTH_ENABLED is true.
  Can be disabled in favor of OIDC-only authentication.
  """
  use MydiaWeb, :controller

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Auth.Guardian
  alias Mydia.Config

  # How long a password-verified sign-in may wait for its second factor.
  @pending_totp_ttl_seconds 300

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
        cond do
          not Accounts.verify_password(user, password) ->
            Accounts.record_login_failure(ip_address, username)
            login_error(conn, "Invalid username or password")

          Accounts.totp_enabled?(user) ->
            start_totp_challenge(conn, user)

          true ->
            Accounts.reset_login_rate_limit(ip_address, username)
            sign_in_and_redirect(conn, user)
        end
    end
  end

  # The password was right but the account wants a second factor. Nothing is
  # signed in yet and the rate limit is not reset: that happens only once the
  # code is accepted.
  defp start_totp_challenge(conn, %User{id: user_id}) do
    conn
    |> configure_session(renew: true)
    |> put_session(:pending_totp, %{
      "user_id" => user_id,
      "issued_at" => System.system_time(:second)
    })
    |> redirect(to: ~p"/auth/login/totp")
  end

  # Sign in the user via Guardian, which stores the token in session under the
  # :guardian_default_token key that VerifySession expects. Also store under
  # :guardian_token for backward compatibility with code that reads that key
  # directly (e.g., logout, Flutter cookie auth).
  defp sign_in_and_redirect(conn, user) do
    Accounts.update_last_login(user)
    {:ok, token, _claims} = Guardian.create_token(user)

    conn
    |> Guardian.Plug.sign_in(user)
    |> put_session(:guardian_default_token, token)
    |> put_session(:guardian_token, token)
    |> put_flash(:info, "Successfully logged in!")
    |> redirect(to: "/")
  end

  @doc """
  Renders the second-factor challenge for a sign-in whose password was verified.
  """
  def totp_new(conn, _params) do
    case pending_totp_user(conn) do
      {:ok, _user} -> render_totp(conn, nil)
      {:error, reason} -> abandon_totp(conn, reason)
    end
  end

  @doc """
  Accepts a TOTP code or recovery code and completes the pending sign-in.
  """
  def totp_create(conn, params) do
    code = totp_code_param(params)

    case pending_totp_user(conn) do
      {:ok, user} -> verify_totp(conn, user, code)
      {:error, reason} -> abandon_totp(conn, reason)
    end
  end

  # `params["totp"]` is client-controlled and this endpoint parses JSON
  # bodies, so it can be anything: a map without "code", a bare string, a
  # list, etc. Pattern match instead of `get_in/2`, which raises inside
  # `Access.get/3` when an intermediate value isn't a map.
  defp totp_code_param(%{"totp" => %{"code" => code}}) when is_binary(code), do: code
  defp totp_code_param(_params), do: ""

  defp verify_totp(conn, user, code) do
    ip_address = remote_ip(conn)

    # `reserve_second_factor_attempt/2` counts this attempt atomically before
    # the code is even checked, closing the race where parallel requests could
    # all pass a read-only check before any of them recorded a failure. A
    # wrong code needs no separate `record_login_failure/2`: the reservation
    # already counted it.
    with :ok <- Accounts.reserve_second_factor_attempt(ip_address, user.username),
         :ok <- Accounts.verify_second_factor(user, code) do
      Accounts.reset_login_rate_limit(ip_address, user.username)

      conn
      |> delete_session(:pending_totp)
      |> configure_session(renew: true)
      |> sign_in_and_redirect(user)
    else
      {:error, :rate_limited} ->
        render_totp(conn, "Too many login attempts. Please try again later.")

      {:error, :invalid_code} ->
        render_totp(conn, "Invalid code")
    end
  end

  defp pending_totp_user(conn) do
    case get_session(conn, :pending_totp) do
      %{"user_id" => user_id, "issued_at" => issued_at} ->
        with true <- System.system_time(:second) - issued_at <= @pending_totp_ttl_seconds,
             %User{} = user <- Accounts.get_user_by_id(user_id),
             true <- Accounts.totp_enabled?(user) do
          {:ok, user}
        else
          _ -> {:error, :expired}
        end

      _ ->
        {:error, :missing}
    end
  end

  defp abandon_totp(conn, :missing), do: redirect(conn, to: ~p"/auth/login")

  defp abandon_totp(conn, :expired) do
    conn
    |> delete_session(:pending_totp)
    |> put_flash(:error, "Sign-in expired, please try again")
    |> redirect(to: ~p"/auth/login")
  end

  defp render_totp(conn, error) do
    render(conn, :totp, error: error)
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
