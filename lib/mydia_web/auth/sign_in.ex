defmodule MydiaWeb.Auth.SignIn do
  @moduledoc """
  Starts a browser session for a user who has finished every sign-in step
  (password, second factor, or passkey).

  Guardian stores the token under `:guardian_default_token`, which
  `VerifySession` expects. It is also stored under `:guardian_token` for code
  that reads that key directly (logout, Flutter cookie auth).
  """

  import Plug.Conn

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Auth.Guardian

  @spec sign_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def sign_in(conn, %User{} = user) do
    Accounts.update_last_login(user)
    {:ok, token, _claims} = Guardian.create_token(user)

    conn
    |> Guardian.Plug.sign_in(user)
    |> put_session(:guardian_default_token, token)
    |> put_session(:guardian_token, token)
  end

  @doc "The client IP as a string, the key the login rate limiter uses."
  @spec remote_ip(Plug.Conn.t()) :: String.t()
  def remote_ip(%Plug.Conn{remote_ip: remote_ip}) do
    case remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
      _ -> "unknown"
    end
  end
end
