defmodule MydiaWeb.Schema.AuthResolverTotpTest do
  use MydiaWeb.ConnCase

  import Mydia.AccountsFixtures

  @password "correct-horse-battery-staple"

  @login """
  mutation Login($input: LoginInput!) {
    login(input: $input) { token expiresIn totpRequired challengeToken user { id email } }
  }
  """

  @verify """
  mutation VerifyTotp($input: VerifyTotpInput!) {
    verifyTotp(input: $input) { token expiresIn totpRequired user { id } }
  }
  """

  setup do
    totp_user_fixture(%{password: @password})
  end

  defp caller, do: %{remote_ip: "198.51.100.#{System.unique_integer([:positive])}"}

  defp login(username, context) do
    Absinthe.run(@login, MydiaWeb.Schema,
      variables: %{
        "input" => %{
          "username" => username,
          "password" => @password,
          "deviceId" => "totp-device-#{System.unique_integer([:positive])}",
          "deviceName" => "Test Device",
          "platform" => "web"
        }
      },
      context: context
    )
  end

  defp verify(token, code, context) do
    Absinthe.run(@verify, MydiaWeb.Schema,
      variables: %{"input" => %{"challengeToken" => token, "code" => code}},
      context: context
    )
  end

  test "a password-only account gets a token and totpRequired false", %{conn: _conn} do
    plain = user_fixture(%{password: @password})

    assert {:ok, %{data: %{"login" => %{"token" => token, "totpRequired" => false}}}} =
             login(plain.username, caller())

    assert is_binary(token)
  end

  test "a TOTP account gets a challenge and no token or profile", %{user: user} do
    assert {:ok, %{data: %{"login" => result}}} = login(user.username, caller())

    assert result["totpRequired"] == true
    assert is_binary(result["challengeToken"])
    assert result["token"] == nil
    assert result["user"] == nil
    assert result["expiresIn"] == nil
  end

  test "verifyTotp issues a device token", %{user: user, secret: secret} do
    context = caller()
    {:ok, %{data: %{"login" => %{"challengeToken" => challenge}}}} = login(user.username, context)

    assert {:ok, %{data: %{"verifyTotp" => result}}} =
             verify(challenge, NimbleTOTP.verification_code(secret), context)

    assert is_binary(result["token"])
    assert result["totpRequired"] == false
    assert result["user"]["id"] == user.id

    assert {:ok, _user, %{"device_id" => device_id}} =
             Mydia.Auth.Guardian.verify_token_with_claims(result["token"])

    assert is_binary(device_id)
  end

  test "verifyTotp rejects a wrong code", %{user: user} do
    context = caller()
    {:ok, %{data: %{"login" => %{"challengeToken" => challenge}}}} = login(user.username, context)

    assert {:ok, %{errors: [%{message: "Invalid code"}]}} = verify(challenge, "abc", context)
  end

  test "verifyTotp rejects a tampered or expired challenge", %{user: user, secret: secret} do
    code = NimbleTOTP.verification_code(secret)

    assert {:ok, %{errors: [%{message: "Sign-in expired, please try again"}]}} =
             verify("not-a-token", code, caller())

    stale =
      Phoenix.Token.sign(
        MydiaWeb.Endpoint,
        "totp challenge",
        %{
          "user_id" => user.id,
          "device_id" => "d",
          "device_name" => "n",
          "platform" => "web"
        },
        signed_at: System.system_time(:second) - 301
      )

    assert {:ok, %{errors: [%{message: "Sign-in expired, please try again"}]}} =
             verify(stale, code, caller())
  end

  test "verifyTotp code failures share login's rate-limit bucket for an email login", %{
    user: user
  } do
    {:ok, %{data: %{"login" => %{"challengeToken" => challenge}}}} =
      login(user.email, caller())

    for _ <- 1..10 do
      assert {:ok, %{errors: [%{message: "Invalid code"}]}} = verify(challenge, "abc", caller())
    end

    assert {:ok, %{errors: [%{message: message}]}} = login(user.email, caller())
    assert message =~ "Too many login attempts"
  end
end
