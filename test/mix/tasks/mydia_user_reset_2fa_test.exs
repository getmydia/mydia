defmodule Mix.Tasks.Mydia.UserReset2faTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "reset-2fa turns TOTP off" do
    %{user: user} = totp_user_fixture()

    Mix.Tasks.Mydia.User.run(["reset-2fa", user.username])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "Two-factor authentication turned off"
    refute Mydia.Accounts.totp_enabled?(Mydia.Accounts.get_user!(user.id))
  end

  test "reset-2fa on an account without TOTP says so" do
    user = user_fixture()

    Mix.Tasks.Mydia.User.run(["reset-2fa", user.username])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "does not have two-factor authentication"
  end
end
