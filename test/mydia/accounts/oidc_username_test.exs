defmodule Mydia.Accounts.OidcUsernameTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts

  defp upsert(attrs, sub \\ nil) do
    sub = sub || "sub-#{System.unique_integer([:positive])}"
    {:ok, user} = Accounts.upsert_user_from_oidc(sub, "https://issuer.example.test", attrs)
    user
  end

  setup do
    # An admin has to exist first, or upsert_user_from_oidc/3 promotes the
    # account under test to admin and the role assertions read oddly.
    admin_user_fixture(%{username: "installer"})
    :ok
  end

  test "a new SSO account is named from the IdP claim" do
    user = upsert(%{email: "robin@example.test", preferred_username: "tonix", role: "user"})

    assert user.username == "tonix"
    assert user.username_source == "idp"
  end

  test "a new SSO account with no claim is named from its email" do
    user = upsert(%{email: "robin.vega@example.test", role: "user"})

    assert user.username == "robin.vega"
    assert user.username_source == "email"
  end

  test "a new SSO account with neither is named from its sub" do
    user = upsert(%{role: "user"}, "abcdef1234567890")

    assert user.username == "oidc-abcdef12"
    assert user.username_source == "sub"
  end

  test "a later login upgrades an email-derived name to the IdP claim" do
    sub = "sub-upgrade"
    first = upsert(%{email: "robin@example.test", role: "user"}, sub)
    assert first.username == "robin"

    second = upsert(%{email: "robin@example.test", preferred_username: "tonix"}, sub)

    assert second.username == "tonix"
    assert second.username_source == "idp"
  end

  test "a later login never downgrades the name" do
    sub = "sub-downgrade"
    first = upsert(%{email: "robin@example.test", preferred_username: "tonix"}, sub)
    assert first.username == "tonix"

    second = upsert(%{email: "robin@example.test"}, sub)

    assert second.username == "tonix"
    assert second.username_source == "idp"
  end

  test "a colliding claim suffixes rather than failing the sign-in" do
    user_fixture(%{username: "tonix"})

    user = upsert(%{email: "robin@example.test", preferred_username: "tonix", role: "user"})

    assert user.username == "tonix-2"
    assert user.username_source == "idp"
  end

  test "a locally chosen name is never overwritten by a login" do
    sub = "sub-local"
    first = upsert(%{email: "robin@example.test", role: "user"}, sub)

    {:ok, renamed} =
      first
      |> Mydia.Accounts.User.username_changeset(%{username: "chosen-by-hand"})
      |> Ecto.Changeset.put_change(:username_source, nil)
      |> Mydia.Repo.update()

    assert renamed.username_source == nil

    second = upsert(%{email: "robin@example.test", preferred_username: "tonix"}, sub)

    assert second.username == "chosen-by-hand"
  end
end
