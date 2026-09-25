defmodule MydiaWeb.ProfileLive.SecondFactorThrottle do
  @moduledoc """
  The login throttle for profile actions that check a password or second
  factor (turning TOTP off, new recovery codes, adding or removing a
  passkey). An authenticated session could otherwise brute-force them with
  no rate limit.

  LiveView has no reliable client IP, so the account itself stands in for
  it; the username bucket is the real username, so profile-page failures
  spend the same per-account budget as password-login failures. The attempt
  is reserved atomically before `fun` runs (see
  `Mydia.Accounts.reserve_second_factor_attempt/2`), so it is counted
  whether `fun` succeeds or fails.
  """

  alias Mydia.Accounts
  alias Mydia.Accounts.User

  @spec run(User.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def run(%User{} = user, fun) do
    ip_key = "profile:#{user.id}"

    with :ok <- Accounts.reserve_second_factor_attempt(ip_key, user.username),
         {:ok, _} = ok <- fun.() do
      Accounts.reset_login_rate_limit(ip_key, user.username)
      ok
    end
  end
end
