defmodule Mydia.Accounts.TotpTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.Totp

  @now 1_790_000_010

  describe "encrypt/1 and decrypt/1" do
    test "round-trips a secret" do
      secret = Totp.generate_secret()

      assert {:ok, ^secret} = secret |> Totp.encrypt() |> Totp.decrypt()
    end

    test "rejects tampered or missing ciphertext" do
      ciphertext = Totp.encrypt(Totp.generate_secret())

      assert :error = Totp.decrypt(ciphertext <> "x")
      assert :error = Totp.decrypt(nil)
    end
  end

  describe "valid_code?/4" do
    setup do
      %{secret: Totp.generate_secret()}
    end

    test "accepts the current step and returns its start", %{secret: secret} do
      code = NimbleTOTP.verification_code(secret, time: @now)
      step = div(@now, 30) * 30

      assert {:ok, accepted} = Totp.valid_code?(secret, code, nil, @now)
      assert DateTime.to_unix(accepted) == step
    end

    test "accepts the previous step for clock drift", %{secret: secret} do
      code = NimbleTOTP.verification_code(secret, time: @now - 30)

      assert {:ok, _} = Totp.valid_code?(secret, code, nil, @now)
    end

    test "rejects a code two steps old", %{secret: secret} do
      code = NimbleTOTP.verification_code(secret, time: @now - 60)

      assert :error = Totp.valid_code?(secret, code, nil, @now)
    end

    test "rejects a step already used", %{secret: secret} do
      code = NimbleTOTP.verification_code(secret, time: @now)
      {:ok, used} = Totp.valid_code?(secret, code, nil, @now)

      assert :error = Totp.valid_code?(secret, code, used, @now)
    end

    test "rejects a wrong code", %{secret: secret} do
      right = NimbleTOTP.verification_code(secret, time: @now)
      wrong = if right == "000000", do: "111111", else: "000000"

      assert :error = Totp.valid_code?(secret, wrong, nil, @now)
    end
  end

  describe "recovery codes" do
    test "generates 10 distinct codes shaped xxxxx-xxxxx" do
      codes = Totp.generate_recovery_codes()

      assert length(codes) == 10
      assert length(Enum.uniq(codes)) == 10
      assert Enum.all?(codes, &Regex.match?(~r/\A[a-z2-7]{5}-[a-z2-7]{5}\z/, &1))
    end

    test "normalize_code/1 strips whitespace and dashes and lowercases" do
      assert Totp.normalize_code(" ABCDE-fghij \n") == "abcdefghij"
      assert Totp.normalize_code("123 456") == "123456"
    end

    test "code_kind/1 classifies normalized input" do
      assert Totp.code_kind("123456") == :totp
      assert Totp.code_kind("abcde23456") == :recovery
      assert Totp.code_kind("12345") == :invalid
      assert Totp.code_kind("abcde1") == :invalid
    end
  end

  test "otpauth_uri/2 names the issuer and the account" do
    uri = Totp.otpauth_uri("admin", Totp.generate_secret())

    assert uri =~ "otpauth://totp/Mydia:admin"
    assert uri =~ "issuer=Mydia"
  end
end
