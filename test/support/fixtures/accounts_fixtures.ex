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
end
