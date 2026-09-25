defmodule Mydia.AccountsTotpTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.Totp

  describe "enrollment" do
    test "begin_totp_enrollment/1 persists nothing" do
      user = user_fixture()

      assert %{secret: secret, uri: uri} = Accounts.begin_totp_enrollment(user)
      assert is_binary(secret)
      assert uri =~ "otpauth://totp/"
      refute Accounts.totp_enabled?(Accounts.get_user!(user.id))
    end

    test "confirm_totp_enrollment/3 enables TOTP and returns 10 recovery codes" do
      user = user_fixture()
      %{secret: secret} = Accounts.begin_totp_enrollment(user)

      assert {:ok, user, codes} =
               Accounts.confirm_totp_enrollment(
                 user,
                 secret,
                 NimbleTOTP.verification_code(secret)
               )

      assert Accounts.totp_enabled?(user)
      assert length(codes) == 10
      assert Accounts.recovery_codes_remaining(user) == 10
      assert {:ok, ^secret} = Totp.decrypt(user.totp_secret_encrypted)
    end

    test "confirm_totp_enrollment/3 rejects a wrong code and persists nothing" do
      user = user_fixture()
      %{secret: secret} = Accounts.begin_totp_enrollment(user)
      wrong = if NimbleTOTP.verification_code(secret) == "000000", do: "111111", else: "000000"

      assert {:error, :invalid_code} = Accounts.confirm_totp_enrollment(user, secret, wrong)
      refute Accounts.totp_enabled?(Accounts.get_user!(user.id))
    end

    test "confirm_totp_enrollment/3 refuses to overwrite an already-enabled secret" do
      user = user_fixture()
      %{secret: first_secret} = Accounts.begin_totp_enrollment(user)

      assert {:ok, user, _codes} =
               Accounts.confirm_totp_enrollment(
                 user,
                 first_secret,
                 NimbleTOTP.verification_code(first_secret)
               )

      %{secret: second_secret} = Accounts.begin_totp_enrollment(user)

      assert {:error, :already_enabled} =
               Accounts.confirm_totp_enrollment(
                 user,
                 second_secret,
                 NimbleTOTP.verification_code(second_secret)
               )

      reloaded = Accounts.get_user!(user.id)
      assert Accounts.totp_enabled?(reloaded)
      assert {:ok, ^first_secret} = Totp.decrypt(reloaded.totp_secret_encrypted)
    end
  end

  describe "verify_second_factor/2" do
    setup do
      totp_user_fixture()
    end

    test "accepts a current TOTP code once", %{user: user, secret: secret} do
      code = NimbleTOTP.verification_code(secret)

      assert :ok = Accounts.verify_second_factor(user, code)

      assert {:error, :invalid_code} =
               Accounts.verify_second_factor(Accounts.get_user!(user.id), code)
    end

    test "rejects the same code even with a stale user struct", %{user: user, secret: secret} do
      code = NimbleTOTP.verification_code(secret)

      assert :ok = Accounts.verify_second_factor(user, code)
      # `user` still has totp_last_used_at: nil; the conditional UPDATE must catch it.
      assert {:error, :invalid_code} = Accounts.verify_second_factor(user, code)
    end

    test "accepts each recovery code once, with or without its dash", %{
      user: user,
      recovery_codes: [first, second | _]
    } do
      assert :ok = Accounts.verify_second_factor(user, first)
      assert {:error, :invalid_code} = Accounts.verify_second_factor(user, first)

      assert :ok =
               Accounts.verify_second_factor(user, String.upcase(String.replace(second, "-", "")))

      assert Accounts.recovery_codes_remaining(user) == 8
    end

    test "rejects garbage", %{user: user} do
      assert {:error, :invalid_code} = Accounts.verify_second_factor(user, "nope")
      assert {:error, :invalid_code} = Accounts.verify_second_factor(user, "")
    end

    test "rejects TOTP but still accepts recovery codes when the secret cannot be decrypted", %{
      user: user,
      secret: secret,
      recovery_codes: [code | _]
    } do
      user =
        user
        |> Mydia.Accounts.User.totp_changeset(%{totp_secret_encrypted: "not-decryptable"})
        |> Mydia.Repo.update!()

      assert {:error, :invalid_code} =
               Accounts.verify_second_factor(user, NimbleTOTP.verification_code(secret))

      assert :ok = Accounts.verify_second_factor(user, code)
    end

    test "a user without TOTP never passes", %{} do
      assert {:error, :invalid_code} = Accounts.verify_second_factor(user_fixture(), "123456")
    end
  end

  describe "disable, reset, regenerate" do
    setup do
      totp_user_fixture(%{password: "correct-horse-battery-staple"})
    end

    test "disable_totp/3 needs the password and a code", %{user: user, secret: secret} do
      code = NimbleTOTP.verification_code(secret)

      assert {:error, :invalid_password} = Accounts.disable_totp(user, "wrong", code)

      assert {:error, :invalid_code} =
               Accounts.disable_totp(user, "correct-horse-battery-staple", "000000x")

      assert {:ok, user} = Accounts.disable_totp(user, "correct-horse-battery-staple", code)
      refute Accounts.totp_enabled?(user)
      assert user.totp_secret_encrypted == nil
      assert Accounts.recovery_codes_remaining(user) == 0
    end

    test "admin_reset_totp/1 clears everything", %{user: user} do
      assert {:ok, user} = Accounts.admin_reset_totp(user)
      refute Accounts.totp_enabled?(user)
      assert Accounts.recovery_codes_remaining(user) == 0
    end

    test "regenerate_recovery_codes/2 replaces the old set", %{
      user: user,
      secret: secret,
      recovery_codes: [old | _]
    } do
      assert {:ok, new_codes} =
               Accounts.regenerate_recovery_codes(user, NimbleTOTP.verification_code(secret))

      assert length(new_codes) == 10
      assert {:error, :invalid_code} = Accounts.verify_second_factor(user, old)
      assert :ok = Accounts.verify_second_factor(user, hd(new_codes))
    end
  end
end
