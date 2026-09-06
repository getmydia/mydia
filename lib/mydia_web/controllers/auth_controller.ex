defmodule MydiaWeb.AuthController do
  @moduledoc """
  Handles OIDC authentication flow.

  Provides login, callback, and logout actions for OpenID Connect authentication.
  """
  use MydiaWeb, :controller

  # Use RuntimeUeberauth to read OIDC config at runtime instead of compile time
  # This is necessary because OIDC providers are configured via environment
  # variables in runtime.exs, which aren't available during compilation
  plug MydiaWeb.Plugs.RuntimeUeberauth

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian

  require Logger

  @doc """
  Initiates OIDC login by redirecting to the identity provider.

  This action is called after the Ueberauth plug has processed the request.
  If Ueberauth encountered an error, we handle it here.
  Otherwise, Ueberauth has already halted the connection and redirected.
  """
  def request(conn, params) do
    Logger.debug("OIDC request called with params: #{inspect(params)}")
    Logger.debug("Connection halted? #{conn.halted}")
    Logger.debug("Response sent? #{conn.state}")

    # Check if OIDC is configured
    if oidc_configured?() do
      # If we reach here and the connection wasn't halted by Ueberauth,
      # it means there was an error or the strategy didn't run.
      # Check if there's a ueberauth_failure assign
      case conn.assigns do
        %{ueberauth_failure: failure} ->
          Logger.error("Ueberauth failure: #{inspect(failure)}")

          conn
          |> put_flash(:error, "Authentication failed: #{format_errors(failure.errors)}")
          |> redirect(to: "/auth/login")

        _ ->
          # No failure, but also not redirected - this shouldn't happen
          Logger.error("Ueberauth didn't handle the request and no failure was set")

          conn
          |> put_flash(:error, "OIDC authentication configuration error")
          |> redirect(to: "/auth/login")
      end
    else
      Logger.warning("OIDC is not configured, redirecting to login page")

      conn
      |> put_flash(:error, "OIDC authentication is not configured.")
      |> redirect(to: "/auth/login")
    end
  end

  @doc """
  Handles the callback from the OIDC provider.
  Creates or updates the user, signs a JWT token, and redirects to the app.
  """
  def callback(%{assigns: %{ueberauth_failure: fails}} = conn, _params) do
    Logger.error("OIDC callback failure: #{inspect(fails)}")

    conn
    |> put_flash(:error, "Authentication failed: #{format_errors(fails.errors)}")
    |> redirect(to: "/auth/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case process_oidc_auth(auth) do
      {:ok, user} ->
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
        |> put_flash(:info, "Successfully authenticated!")
        |> redirect(to: "/")

      {:error, reason} ->
        Logger.error("OIDC authentication failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Authentication failed: #{inspect(reason)}")
        |> redirect(to: "/auth/login")
    end
  end

  @doc """
  Auto-login endpoint for first-time setup.

  Accepts a valid Guardian token in the query params and sets up the session.
  This is used after initial admin user creation to automatically log them in.
  """
  def auto_login(conn, %{"token" => token}) do
    case Guardian.decode_and_verify(token) do
      {:ok, claims} ->
        case Accounts.get_user!(claims["sub"]) do
          nil ->
            conn
            |> put_flash(:error, "Invalid authentication token")
            |> redirect(to: "/")

          user ->
            conn
            |> Guardian.Plug.sign_in(user)
            |> put_session(:guardian_default_token, token)
            |> put_session(:guardian_token, token)
            |> redirect(to: "/")
        end

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid or expired authentication token")
        |> redirect(to: "/")
    end
  end

  @doc """
  Logs out the user by revoking the token and clearing the session.
  """
  def logout(conn, _params) do
    token = get_session(conn, :guardian_token)

    if token do
      Guardian.revoke_token(token)
    end

    conn
    |> Guardian.Plug.sign_out()
    |> clear_session()
    |> put_flash(:info, "You have been logged out")
    |> redirect(to: "/")
  end

  # Process OIDC authentication and create/update user
  defp process_oidc_auth(auth) do
    # Extract OIDC claims
    oidc_sub = auth.uid
    oidc_issuer = auth.provider |> to_string()

    # Extract user information from OIDC claims
    attrs = %{
      email: auth.info.email,
      display_name: auth.info.name || auth.info.email,
      avatar_url: auth.info.image,
      role: determine_role(auth),
      preferred_username: preferred_username(auth)
    }

    # Create or update user from OIDC
    Accounts.upsert_user_from_oidc(oidc_sub, oidc_issuer, attrs)
  end

  # `preferred_username` is a standard OIDC claim. Ueberauth's Info struct has
  # a `nickname` field and the OIDC strategies map the claim onto it, but not
  # every strategy does, so the raw userinfo is the second look.
  defp preferred_username(auth) do
    userinfo =
      case auth.extra do
        %{raw_info: %{userinfo: userinfo}} when is_map(userinfo) -> userinfo
        _other -> %{}
      end

    blank_to_nil(Map.get(auth.info, :nickname)) ||
      blank_to_nil(Map.get(userinfo, "preferred_username"))
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # Determine user role from OIDC claims
  # Can be customized based on your OIDC provider's group/role claims
  defp determine_role(auth) do
    # Access raw_info struct fields (not using bracket notation on structs)
    raw_info = auth.extra.raw_info
    userinfo = raw_info.userinfo || %{}

    # Check for role in userinfo (customize this based on your OIDC provider)
    roles = Map.get(userinfo, "roles", [])
    groups = Map.get(userinfo, "groups", [])

    cond do
      "admin" in roles or "administrators" in groups -> "admin"
      "user" in roles or "users" in groups -> "user"
      "readonly" in roles or "readers" in groups -> "readonly"
      # Default role
      true -> "user"
    end
  end

  # Format Ueberauth errors for display with detailed information
  defp format_errors(errors) do
    errors
    |> Enum.map_join(", ", fn error ->
      # Include both message and message_key for more context
      case error do
        %{message: msg, message_key: key} when key != nil ->
          "#{msg} (#{key})"

        %{message: msg} ->
          msg

        _ ->
          inspect(error)
      end
    end)
  end

  # Check if OIDC is configured
  defp oidc_configured? do
    case Application.get_env(:ueberauth, Ueberauth) do
      nil -> false
      config -> Keyword.get(config, :providers, []) != []
    end
  end
end
