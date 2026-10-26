defmodule Mydia.Accounts.OidcLinkTest do
  # Not async: toggles :runtime_config in Application env.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.User

  @issuer "oidc"

  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    :ok
  end

  defp put_auth(fields) do
    config = Mydia.Config.get()
    Application.put_env(:mydia, :runtime_config, %{config | auth: struct(config.auth, fields)})
  end

  defp sso_attrs(email, extra \\ %{}) do
    Map.merge(%{email: email, display_name: "Fictional Person", role: "user"}, extra)
  end

  describe "link_oidc_identity/3" do
    test "attaches sub and issuer to a local user" do
      user = user_fixture()

      assert {:ok, %User{oidc_sub: "sub-1", oidc_issuer: @issuer}} =
               Accounts.link_oidc_identity(user, "sub-1", @issuer)

      assert Accounts.get_user_by_oidc("sub-1", @issuer).id == user.id
    end

    test "refuses an account that is already linked" do
      user = user_fixture()
      {:ok, user} = Accounts.link_oidc_identity(user, "sub-1", @issuer)
      assert {:error, :already_linked} = Accounts.link_oidc_identity(user, "sub-2", @issuer)
    end

    # Two sign-ins can auto-link the same account at once: each loaded it
    # with no identity. The write must check the database, not the struct.
    test "refuses a stale struct whose account was linked meanwhile" do
      user = user_fixture()
      {:ok, _} = Accounts.link_oidc_identity(user, "sub-1", @issuer)

      assert user.oidc_sub == nil
      assert {:error, :already_linked} = Accounts.link_oidc_identity(user, "sub-2", @issuer)

      assert Repo.get!(User, user.id).oidc_sub == "sub-1"
      assert Accounts.get_user_by_oidc("sub-2", @issuer) == nil
    end

    test "refuses an identity that belongs to another account" do
      other = user_fixture()
      {:ok, _} = Accounts.link_oidc_identity(other, "sub-1", @issuer)

      assert {:error, :identity_taken} =
               Accounts.link_oidc_identity(user_fixture(), "sub-1", @issuer)
    end
  end

  describe "unlink_oidc_identity/1" do
    test "clears the identity of a user with a password" do
      {:ok, user} = Accounts.link_oidc_identity(user_fixture(), "sub-1", @issuer)
      assert Accounts.can_unlink_oidc?(user)
      assert {:ok, %User{oidc_sub: nil, oidc_issuer: nil}} = Accounts.unlink_oidc_identity(user)
    end

    test "refuses an SSO-only account" do
      user = oidc_user_fixture()
      refute Accounts.can_unlink_oidc?(user)
      assert Accounts.oidc_unlink_blocker(user) == :no_local_credential
      assert {:error, :no_local_credential} = Accounts.unlink_oidc_identity(user)
    end

    test "refuses when local auth is disabled" do
      {:ok, user} = Accounts.link_oidc_identity(user_fixture(), "sub-1", @issuer)
      put_auth(local_enabled: false)
      assert Accounts.oidc_unlink_blocker(user) == :local_auth_disabled
      assert {:error, :local_auth_disabled} = Accounts.unlink_oidc_identity(user)
    end

    test "refuses an unlinked account" do
      assert {:error, :not_linked} = Accounts.unlink_oidc_identity(user_fixture())
    end
  end

  describe "auth_method/1" do
    test "names local, SSO-only and linked accounts" do
      local = user_fixture()
      {:ok, linked} = Accounts.link_oidc_identity(user_fixture(), "sub-1", @issuer)

      assert Accounts.auth_method(local) == :local
      assert Accounts.auth_method(oidc_user_fixture()) == :oidc
      assert Accounts.auth_method(linked) == :local_and_oidc
      assert Accounts.auth_method_label(linked) == "Local + SSO"
    end
  end

  describe "upsert_user_from_oidc/3 claim refresh" do
    # The IdP now reports an email another local account already uses. The
    # identity is still valid, so the sign-in goes through on the old email.
    test "keeps the local email when the IdP email belongs to another account" do
      user = oidc_user_fixture(%{email: "sso-own@example.test"})
      user_fixture(%{email: "taken@example.test"})

      assert {:ok, signed_in} =
               Accounts.upsert_user_from_oidc(
                 user.oidc_sub,
                 user.oidc_issuer,
                 sso_attrs("taken@example.test", %{display_name: "Renamed Person"})
               )

      assert signed_in.id == user.id
      assert signed_in.email == "sso-own@example.test"
      assert signed_in.display_name == "Renamed Person"
      assert Repo.get!(User, user.id).email == "sso-own@example.test"
    end
  end

  describe "upsert_user_from_oidc/3 email auto-link" do
    test "links the matching local account when enabled and verified" do
      put_auth(oidc_link_by_email: true)
      local = user_fixture(%{email: "Pat@Example.test", role: "readonly"})

      assert {:ok, user} =
               Accounts.upsert_user_from_oidc(
                 "sub-9",
                 @issuer,
                 sso_attrs("pat@example.test", %{email_verified: true, role: "admin"})
               )

      assert user.id == local.id
      assert user.oidc_sub == "sub-9"
      assert user.role == "readonly"
      assert user.password_hash
    end

    test "does not link when the flag is off" do
      user_fixture(%{email: "pat@example.test"})

      assert {:error, :email_taken} =
               Accounts.upsert_user_from_oidc(
                 "sub-9",
                 @issuer,
                 sso_attrs("pat@example.test", %{email_verified: true})
               )
    end

    test "does not link when the email is unverified" do
      put_auth(oidc_link_by_email: true)
      user_fixture(%{email: "pat@example.test"})

      assert {:error, :email_taken} =
               Accounts.upsert_user_from_oidc("sub-9", @issuer, sso_attrs("pat@example.test"))
    end

    test "does not link a target that already has another identity" do
      put_auth(oidc_link_by_email: true)

      {:ok, _} =
        Accounts.link_oidc_identity(user_fixture(%{email: "pat@example.test"}), "sub-1", @issuer)

      assert {:error, :email_taken} =
               Accounts.upsert_user_from_oidc(
                 "sub-9",
                 @issuer,
                 sso_attrs("pat@example.test", %{email_verified: true})
               )
    end

    test "does not link when two accounts differ only by email case" do
      put_auth(oidc_link_by_email: true)
      a = user_fixture(%{email: "Pat@example.test"})
      b = user_fixture(%{email: "pat@example.test"})

      assert {:error, :email_taken} =
               Accounts.upsert_user_from_oidc(
                 "sub-9",
                 @issuer,
                 sso_attrs("pat@example.test", %{email_verified: true})
               )

      assert Accounts.get_user_by_oidc("sub-9", @issuer) == nil
      assert Repo.get!(User, a.id).oidc_sub == nil
      assert Repo.get!(User, b.id).oidc_sub == nil
    end

    test "creates a new account when no email matches" do
      put_auth(oidc_link_by_email: true)
      user_fixture()

      assert {:ok, %User{oidc_sub: "sub-9"}} =
               Accounts.upsert_user_from_oidc(
                 "sub-9",
                 @issuer,
                 sso_attrs("someone-new@example.test", %{email_verified: true})
               )
    end
  end
end
