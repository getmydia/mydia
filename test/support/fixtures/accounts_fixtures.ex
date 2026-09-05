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
  Generate an OIDC-provisioned user, which has no username.

  `Accounts.upsert_user_from_oidc/3` is the only path that creates one:
  `create_user/1` runs `User.changeset/2`, which requires a username, so it
  cannot build the account shape that SSO installs actually have.
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
end
