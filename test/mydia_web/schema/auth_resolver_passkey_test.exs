defmodule MydiaWeb.Schema.AuthResolverPasskeyTest do
  use MydiaWeb.ConnCase

  import Mydia.AccountsFixtures

  @password "correct-horse-battery-staple"

  @login """
  mutation Login($input: LoginInput!) {
    login(input: $input) { token totpRequired challengeToken }
  }
  """

  defp login(user) do
    Absinthe.run(@login, MydiaWeb.Schema,
      variables: %{
        "input" => %{
          "username" => user.username,
          "password" => @password,
          "deviceId" => "passkey-device-#{System.unique_integer([:positive])}",
          "deviceName" => "Test Device",
          "platform" => "web"
        }
      },
      context: %{remote_ip: "198.51.100.#{System.unique_integer([:positive])}"}
    )
  end

  test "a passkey-only 2FA account cannot sign in from the player with a password" do
    user = user_fixture(%{password: @password})
    passkey_fixture(user, password: @password)

    assert {:ok, %{errors: [%{message: message}]}} = login(user)

    assert message ==
             "This account signs in with a passkey. Add TOTP on your profile to sign in from the player."
  end

  test "a TOTP account with a passkey still gets the TOTP challenge" do
    %{user: user} = totp_user_fixture(%{password: @password})
    passkey_fixture(user, password: @password)

    assert {:ok, %{data: %{"login" => %{"totpRequired" => true, "challengeToken" => token}}}} =
             login(user)

    assert is_binary(token)
  end
end
