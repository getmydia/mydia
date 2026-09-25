defmodule MydiaWeb.PasskeyController do
  @moduledoc """
  Passwordless sign-in with a passkey.

  `options/2` stores a challenge in the session and returns the request
  options; `login/2` verifies the browser's assertion and signs the user in.
  A passkey proves possession plus user verification, so no TOTP follows it.
  Both answer JSON. The browser side is `assets/js/hooks/passkey.mjs`.
  """
  use MydiaWeb, :controller

  alias Mydia.Accounts
  alias Mydia.Config
  alias MydiaWeb.Auth.SignIn
  alias MydiaWeb.PasskeySession

  @unavailable "Passkeys are not available here"
  @expired "Sign-in expired, please try again"
  @rejected "Passkey not recognised"
  @rate_limited "Too many login attempts. Please try again later."

  def options(conn, _params) do
    with true <- Config.get().auth.local_enabled,
         {:ok, rp} <- PasskeySession.relying_party(conn) do
      {challenge, options} = Accounts.passkey_authentication_challenge(rp.rp_id, rp.origin, nil)

      conn
      |> PasskeySession.put_challenge(:login, challenge)
      |> json(%{publicKey: options})
    else
      _ -> PasskeySession.json_error(conn, :not_found, @unavailable)
    end
  end

  def login(conn, params) do
    {challenge, conn} = PasskeySession.pop_challenge(conn, :login)

    cond do
      not Config.get().auth.local_enabled ->
        PasskeySession.json_error(conn, :not_found, @unavailable)

      is_nil(challenge) ->
        PasskeySession.json_error(conn, :bad_request, @expired)

      true ->
        verify(conn, challenge, PasskeySession.credential_param(params))
    end
  end

  defp verify(conn, challenge, credential) do
    ip_address = SignIn.remote_ip(conn)
    rate_key = rate_limit_key(credential)

    with :ok <- Accounts.check_login_rate_limit(ip_address, rate_key),
         {:ok, user} <- Accounts.authenticate_passkey(challenge, credential) do
      Accounts.reset_login_rate_limit(ip_address, rate_key)

      conn
      |> configure_session(renew: true)
      |> SignIn.sign_in(user)
      |> put_flash(:info, "Successfully logged in!")
      |> json(%{redirect: "/"})
    else
      {:error, :rate_limited} ->
        PasskeySession.json_error(conn, :too_many_requests, @rate_limited)

      {:error, :invalid_passkey} ->
        Accounts.record_login_failure(ip_address, rate_key)
        PasskeySession.json_error(conn, :unauthorized, @rejected)
    end
  end

  # The username bucket of the login limiter, keyed on the credential the
  # client claims to hold. The IP bucket still caps a client that rotates ids.
  defp rate_limit_key(%{"id" => id}) when is_binary(id),
    do: "passkey:" <> String.slice(id, 0, 128)

  defp rate_limit_key(_credential), do: "passkey:unknown"
end
