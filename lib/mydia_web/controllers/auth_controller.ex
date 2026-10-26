defmodule MydiaWeb.AuthController do
  @moduledoc """
  Handles OIDC authentication flow.

  Provides login, callback, and logout actions for OpenID Connect authentication.
  """
  use MydiaWeb, :controller

  # Use RuntimeUeberauth to read OIDC config at runtime instead of compile time
  # This is necessary because OIDC providers are configured via environment
  # variables in runtime.exs, which aren't available during compilation
  # The link routes are not Ueberauth routes: they only record an intent and
  # hand off to the normal OIDC request.
  plug MydiaWeb.Plugs.RuntimeUeberauth when action not in [:link, :unlink]

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian

  require Logger

  @link_intent_ttl_seconds 600

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
    if Accounts.oidc_configured?() do
      # If we reach here and the connection wasn't halted by Ueberauth,
      # it means there was an error or the strategy didn't run.
      # Check if there's a ueberauth_failure assign
      case conn.assigns do
        %{ueberauth_failure: failure} ->
          Logger.error("Ueberauth failure: #{inspect(failure)}")

          conn
          |> put_flash(
            :error,
            gettext("Authentication failed: %{errors}", errors: format_errors(failure.errors))
          )
          |> redirect(to: "/auth/login")

        _ ->
          # No failure, but also not redirected - this shouldn't happen
          Logger.error("Ueberauth didn't handle the request and no failure was set")

          conn
          |> put_flash(:error, gettext("OIDC authentication configuration error"))
          |> redirect(to: "/auth/login")
      end
    else
      Logger.warning("OIDC is not configured, redirecting to login page")

      conn
      |> put_flash(:error, gettext("OIDC authentication is not configured."))
      |> redirect(to: "/auth/login")
    end
  end

  @doc """
  Handles the callback from the OIDC provider.
  Creates or updates the user, signs a JWT token, and redirects to the app.
  """
  def callback(%{assigns: %{ueberauth_failure: fails}} = conn, _params) do
    Logger.error("OIDC callback failure: #{inspect(fails)}")
    {intent, conn} = pop_link_intent(conn)

    conn
    |> put_flash(
      :error,
      gettext("Authentication failed: %{errors}", errors: format_errors(fails.errors))
    )
    |> redirect(to: if(intent, do: ~p"/profile", else: "/auth/login"))
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case pop_link_intent(conn) do
      {nil, conn} -> sign_in_with_oidc(conn, auth)
      {intent, conn} -> finish_link(conn, intent, auth)
    end
  end

  # The strategy did not run for this request (no provider claims the path,
  # or OIDC was reconfigured mid-flow), so there is nothing to sign in with.
  def callback(conn, _params) do
    Logger.warning("OIDC callback reached without an Ueberauth result")
    {intent, conn} = pop_link_intent(conn)

    conn
    |> put_flash(:error, gettext("Authentication failed. Please try again."))
    |> redirect(to: if(intent, do: ~p"/profile", else: "/auth/login"))
  end

  @doc """
  Starts linking SSO to the signed-in account: remembers who asked, then hands
  off to the normal OIDC request. The callback finishes the link.

  Routed as `POST /auth/oidc/link` so the browser pipeline's CSRF check
  covers it.
  """
  def link(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    cond do
      not Accounts.oidc_configured?() ->
        conn
        |> put_flash(:error, gettext("OIDC authentication is not configured."))
        |> redirect(to: ~p"/profile")

      Accounts.oidc_user?(user) ->
        conn
        |> put_flash(:error, gettext("Your account is already linked to an SSO account."))
        |> redirect(to: ~p"/profile")

      true ->
        conn
        |> put_session(:oidc_link_intent, %{
          "user_id" => user.id,
          "issued_at" => System.system_time(:second)
        })
        |> redirect(to: "/auth/oidc")
    end
  end

  @doc """
  Detaches SSO from the signed-in account.
  """
  def unlink(conn, _params) do
    case Accounts.unlink_oidc_identity(Guardian.Plug.current_resource(conn)) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, gettext("SSO has been unlinked from your account."))
        |> redirect(to: ~p"/profile")

      {:error, :local_auth_disabled} ->
        conn
        |> put_flash(
          :error,
          gettext("Local sign-in is disabled on this server, so SSO cannot be unlinked.")
        )
        |> redirect(to: ~p"/profile")

      {:error, :no_local_credential} ->
        conn
        |> put_flash(
          :error,
          gettext("Your sign-in is managed by your SSO provider, so it cannot be unlinked.")
        )
        |> redirect(to: ~p"/profile")

      {:error, :not_linked} ->
        redirect(conn, to: ~p"/profile")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, gettext("SSO could not be unlinked. Please try again."))
        |> redirect(to: ~p"/profile")
    end
  end

  defp sign_in_with_oidc(conn, auth) do
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
        |> put_flash(:info, gettext("Successfully authenticated!"))
        |> redirect(to: "/")

      {:error, :email_taken} ->
        sign_in_failed(
          conn,
          gettext(
            "An account with this email already exists. Sign in with your password, then link SSO from your profile."
          )
        )

      # Races in the email auto-link branch, which matched an unlinked local
      # account and then lost it before the write. :identity_taken: another
      # request put this identity on a different account first.
      {:error, :identity_taken} ->
        sign_in_failed(
          conn,
          gettext("This SSO account is already linked to another Mydia account.")
        )

      # :already_linked: another sign-in linked the matched account between
      # the lookup and the conditional write. A retry either finds this
      # identity on it and signs in, or explains the email collision.
      {:error, :already_linked} ->
        sign_in_failed(
          conn,
          gettext("This account was linked to SSO by another sign-in. Please try again.")
        )

      {:error, reason} ->
        Logger.error("OIDC authentication failed: #{inspect(reason)}")

        conn
        |> put_flash(
          :error,
          gettext("Authentication failed: %{errors}", errors: inspect(reason))
        )
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
            |> put_flash(:error, gettext("Invalid authentication token"))
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
        |> put_flash(:error, gettext("Invalid or expired authentication token"))
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
    |> put_flash(:info, gettext("You have been logged out"))
    |> redirect(to: "/")
  end

  defp sign_in_failed(conn, message) do
    conn |> put_flash(:error, message) |> redirect(to: "/auth/login")
  end

  defp pop_link_intent(conn) do
    {get_session(conn, :oidc_link_intent), delete_session(conn, :oidc_link_intent)}
  end

  defp finish_link(conn, %{"user_id" => user_id, "issued_at" => issued_at}, auth)
       when is_integer(issued_at) do
    fresh? = System.system_time(:second) - issued_at <= @link_intent_ttl_seconds

    # session_user/1 loads the account from the database, so link_oidc_identity/3
    # judges "already linked" on current state, not on a struct from the request
    # that started the link.
    with {:fresh, true} <- {:fresh, fresh?},
         {:session, {:ok, user}} <- {:session, session_user(conn)},
         {:owner, true} <- {:owner, user.id == user_id},
         {:ok, _linked} <- Accounts.link_oidc_identity(user, auth.uid, to_string(auth.provider)) do
      conn
      |> put_flash(:info, gettext("Your SSO account is now linked."))
      |> redirect(to: ~p"/profile")
    else
      {:error, :identity_taken} ->
        link_failed(conn, gettext("This SSO account is already linked to another Mydia account."))

      {:error, :already_linked} ->
        link_failed(conn, gettext("Your account is already linked to an SSO account."))

      {:fresh, false} ->
        link_expired(conn, :expired, user_id)

      {:session, _error} ->
        link_expired(conn, :no_session, user_id)

      {:owner, false} ->
        link_expired(conn, :user_mismatch, user_id)
    end
  end

  defp finish_link(conn, _malformed, _auth), do: link_expired(conn, :malformed_intent, nil)

  # The intent's user id is the account that asked to link, not anything from
  # the IdP; the OIDC sub is never logged.
  defp link_expired(conn, reason, user_id) do
    Logger.info("OIDC link not completed: #{reason} (intent user: #{user_id || "unknown"})")
    link_failed(conn, gettext("Linking expired. Please try again."))
  end

  defp link_failed(conn, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/profile")
  end

  # The /auth scope runs no Guardian pipeline, so read the browser session's
  # token directly. A session that is no longer valid cannot finish a link.
  defp session_user(conn) do
    case get_session(conn, :guardian_default_token) do
      nil -> {:error, :no_session}
      token -> Guardian.verify_token(token)
    end
  end

  # Only the boolean `true` counts. Some IdPs send the string "true"; treating
  # that as verified would be guessing, and this claim gates account linking.
  # The flag is read from whichever claim set supplied `auth.info.email`:
  # UeberauthOidcc takes the email from userinfo when that response carries
  # one, and from the ID token otherwise. Mixing the two would let a verified
  # ID-token address vouch for a different, unverified userinfo address.
  defp email_verified?(auth) do
    raw_info =
      case auth.extra do
        %{raw_info: raw_info} when is_map(raw_info) -> raw_info
        _other -> %{}
      end

    userinfo = map_or_empty(Map.get(raw_info, :userinfo))
    claims = map_or_empty(Map.get(raw_info, :claims))
    source = if Map.has_key?(userinfo, "email"), do: userinfo, else: claims

    Map.get(source, "email_verified") == true
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

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
      preferred_username: preferred_username(auth),
      email_verified: email_verified?(auth)
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
end
