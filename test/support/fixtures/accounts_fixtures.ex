defmodule Mydia.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Mydia.Accounts` context.
  """

  alias Mydia.Accounts

  @doc """
  Generate a user.
  """
  def user_fixture(attrs \\ %{}) do
    default_attrs = %{
      username: "testuser#{System.unique_integer([:positive])}",
      email: "user#{System.unique_integer([:positive])}@example.com",
      password: "securepassword123",
      role: "user",
      display_name: "Test User"
    }

    attrs = Map.merge(default_attrs, attrs)

    {:ok, user} = Accounts.create_user(attrs)
    user
  end

  @doc """
  Generate an admin user.
  """
  def admin_user_fixture(attrs \\ %{}) do
    user_fixture(Map.merge(%{role: "admin"}, attrs))
  end

  @doc """
  Generate an OIDC-provisioned user.

  `Accounts.upsert_user_from_oidc/3` is the only path that creates one:
  `create_user/1` runs `User.changeset/2`, which requires a username, so it
  cannot build the account shape that SSO installs actually have.

  The login path now derives a username from the email address, so the
  returned user carries one (e.g. `sso123`). Pass `preferred_username:` to
  exercise the `:idp` tier instead.
  """
  def oidc_user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{email: "sso#{n}@example.test", display_name: "SSO User #{n}", role: "user"},
        attrs
      )

    {:ok, user} =
      Accounts.upsert_user_from_oidc("oidc-sub-#{n}", "https://issuer.example.test", attrs)

    user
  end

  @doc """
  Generate a user with no username at all.

  `oidc_user_fixture/1` no longer produces one: the login path derives a name
  from the email address. This fixture inserts the row directly, bypassing
  every changeset, so it can still build the shape a pre-backfill install has
  and the shape a backfill skip leaves behind.
  """
  def nameless_user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Mydia.Repo.insert!(%Mydia.Accounts.User{
      username: nil,
      username_source: nil,
      email: Map.get(attrs, :email, "nameless#{n}@example.test"),
      display_name: Map.get(attrs, :display_name),
      oidc_sub: Map.get(attrs, :oidc_sub, "oidc-sub-#{n}"),
      oidc_issuer: "https://issuer.example.test",
      role: Map.get(attrs, :role, "user")
    })
  end

  @doc """
  Generate a local user with TOTP enabled.

  Returns the plaintext secret and recovery codes so tests can produce codes
  with `NimbleTOTP.verification_code/1`. Enrollment marks the current 30-second
  step as used; this clears it so the test can sign in with a code from that
  same step instead of waiting for the next one.
  """
  def totp_user_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)
    %{secret: secret} = Accounts.begin_totp_enrollment(user)

    {:ok, user, recovery_codes} =
      Accounts.confirm_totp_enrollment(user, secret, NimbleTOTP.verification_code(secret))

    user =
      user
      |> Mydia.Accounts.User.totp_changeset(%{totp_last_used_at: nil})
      |> Mydia.Repo.update!()

    %{user: user, secret: secret, recovery_codes: recovery_codes}
  end

  @doc """
  Registers a passkey for `user` through the real ceremony with a software
  authenticator. The returned authenticator signs later assertions.
  """
  def passkey_fixture(user, opts \\ []) do
    alias Mydia.SoftAuthenticator

    rp_id = Keyword.get(opts, :rp_id, "mydia.test")
    origin = Keyword.get(opts, :origin, "https://#{rp_id}")
    password = Keyword.get(opts, :password, "securepassword123")
    authn = SoftAuthenticator.new() |> SoftAuthenticator.for_user(user)

    {:ok, {challenge, options}} =
      Accounts.begin_passkey_registration(user, password, rp_id, origin)

    payload = SoftAuthenticator.attest(authn, SoftAuthenticator.ceremony(options, origin))

    {:ok, passkey} =
      Accounts.register_passkey(
        user,
        challenge,
        payload,
        Keyword.get(opts, :name, "Test passkey")
      )

    %{authenticator: authn, passkey: passkey, rp_id: rp_id, origin: origin}
  end
end
