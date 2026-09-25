defmodule Mydia.AccountsPasskeysTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.Passkey
  alias Mydia.SoftAuthenticator

  @password "securepassword123"
  @rp_id "mydia.test"
  @origin "https://mydia.test"

  describe "begin_passkey_registration/4" do
    test "refuses a wrong password" do
      user = user_fixture()

      assert {:error, :invalid_password} =
               Accounts.begin_passkey_registration(user, "wrong", @rp_id, @origin)
    end

    test "excludes the user's existing passkeys on the same host" do
      user = user_fixture()
      %{passkey: here} = passkey_fixture(user)
      passkey_fixture(user, rp_id: "other.test")

      {:ok, {_challenge, options}} =
        Accounts.begin_passkey_registration(user, @password, @rp_id, @origin)

      assert Enum.map(options.excludeCredentials, & &1.id) == [here.credential_id]
    end
  end

  describe "register_passkey/4" do
    test "stores the verified credential" do
      user = user_fixture()
      %{authenticator: authn, passkey: passkey} = passkey_fixture(user, name: "Laptop")

      assert passkey.credential_id == SoftAuthenticator.credential_id(authn)
      assert passkey.rp_id == @rp_id
      assert passkey.name == "Laptop"
      assert passkey.sign_count == 0
      assert [%Passkey{id: id}] = Accounts.list_passkeys(user)
      assert id == passkey.id
    end

    test "rejects the same authenticator twice" do
      user = user_fixture()
      %{authenticator: authn} = passkey_fixture(user)

      {:ok, {challenge, options}} =
        Accounts.begin_passkey_registration(user, @password, @rp_id, @origin)

      payload = SoftAuthenticator.attest(authn, SoftAuthenticator.ceremony(options, @origin))

      assert {:error, :already_registered} =
               Accounts.register_passkey(user, challenge, payload, "Again")
    end

    test "rejects an attestation for another origin" do
      user = user_fixture()

      {:ok, {challenge, options}} =
        Accounts.begin_passkey_registration(user, @password, @rp_id, @origin)

      payload =
        SoftAuthenticator.attest(
          SoftAuthenticator.new(),
          SoftAuthenticator.ceremony(options, @origin),
          origin: "https://evil.test"
        )

      assert {:error, :invalid_passkey} = Accounts.register_passkey(user, challenge, payload, "X")
      assert Accounts.list_passkeys(user) == []
    end
  end

  describe "rename_passkey/3" do
    test "renames only the owner's passkey" do
      user = user_fixture()
      %{passkey: passkey} = passkey_fixture(user)

      assert {:ok, %Passkey{name: "Phone"}} = Accounts.rename_passkey(user, passkey.id, "Phone")
      assert {:error, :not_found} = Accounts.rename_passkey(user_fixture(), passkey.id, "Mine")
      assert {:error, %Ecto.Changeset{}} = Accounts.rename_passkey(user, passkey.id, "")
      assert {:error, :not_found} = Accounts.rename_passkey(user, "not-a-uuid", "Phone")
    end
  end

  describe "delete_passkey/3" do
    test "requires the current password and ownership" do
      user = user_fixture()
      %{passkey: passkey} = passkey_fixture(user)

      assert {:error, :invalid_password} = Accounts.delete_passkey(user, passkey.id, "wrong")
      assert Accounts.has_passkeys?(user)

      other = user_fixture()
      assert {:error, :not_found} = Accounts.delete_passkey(other, passkey.id, @password)

      assert {:ok, _} = Accounts.delete_passkey(user, passkey.id, @password)
      refute Accounts.has_passkeys?(user)
    end
  end

  describe "second_factor_enabled?/1 and has_passkeys?/2" do
    test "is true with TOTP or any passkey" do
      plain = user_fixture()
      refute Accounts.second_factor_enabled?(plain)

      %{user: totp_user} = totp_user_fixture()
      assert Accounts.second_factor_enabled?(totp_user)

      passkey_user = user_fixture()
      passkey_fixture(passkey_user)
      assert Accounts.second_factor_enabled?(passkey_user)
      assert Accounts.has_passkeys?(passkey_user, @rp_id)
      refute Accounts.has_passkeys?(passkey_user, "other.test")
    end
  end

  describe "admin_reset_second_factors/1" do
    test "clears TOTP and passkeys" do
      %{user: user} = totp_user_fixture()
      passkey_fixture(user)

      assert {:ok, user} = Accounts.admin_reset_second_factors(user)
      refute Accounts.totp_enabled?(user)
      refute Accounts.has_passkeys?(user)
      refute Accounts.second_factor_enabled?(user)
    end

    test "turning TOTP off keeps passkeys" do
      %{user: user, secret: secret} = totp_user_fixture()
      passkey_fixture(user)

      assert {:ok, user} =
               Accounts.disable_totp(user, @password, NimbleTOTP.verification_code(secret))

      assert Accounts.has_passkeys?(user)
    end
  end
end
