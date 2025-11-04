defmodule MydiaWeb.AuthController do
  @moduledoc """
  Handles OIDC authentication flow.

  Provides login, callback, and logout actions for OpenID Connect authentication.
  """
  use MydiaWeb, :controller

  plug Ueberauth

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian

  @doc """
  Initiates OIDC login by redirecting to the identity provider.
  """
  def request(conn, _params) do
    # Ueberauth handles the redirect to the OIDC provider
    conn
  end

  @doc """
  Handles the callback from the OIDC provider.
  Creates or updates the user, signs a JWT token, and redirects to the app.
  """
  def callback(%{assigns: %{ueberauth_failure: fails}} = conn, _params) do
    conn
    |> put_flash(:error, "Authentication failed: #{format_errors(fails.errors)}")
    |> redirect(to: "/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case process_oidc_auth(auth) do
      {:ok, user} ->
        # Update last login timestamp
        Accounts.update_last_login(user)

        # Sign the JWT token and store in session
        {:ok, token, _claims} = Guardian.create_token(user)

        conn
        |> Guardian.Plug.sign_in(user)
        |> put_session(:guardian_token, token)
        |> put_flash(:info, "Successfully authenticated!")
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Authentication failed: #{inspect(reason)}")
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
      role: determine_role(auth)
    }

    # Create or update user from OIDC
    Accounts.upsert_user_from_oidc(oidc_sub, oidc_issuer, attrs)
  end

  # Determine user role from OIDC claims
  # Can be customized based on your OIDC provider's group/role claims
  defp determine_role(auth) do
    # Check for role in extra info (customize this based on your OIDC provider)
    roles = get_in(auth.extra, [:raw_info, :userinfo, "roles"]) || []
    groups = get_in(auth.extra, [:raw_info, :userinfo, "groups"]) || []

    cond do
      "admin" in roles or "administrators" in groups -> "admin"
      "user" in roles or "users" in groups -> "user"
      "readonly" in roles or "readers" in groups -> "readonly"
      # Default role
      true -> "user"
    end
  end

  # Format Ueberauth errors for display
  defp format_errors(errors) do
    errors
    |> Enum.map(fn error -> error.message end)
    |> Enum.join(", ")
  end
end
