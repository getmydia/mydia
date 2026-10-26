defmodule Mix.Tasks.Mydia.DeleteAdminTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "labels an admin with a password and linked SSO as Local + SSO" do
    admin = user_fixture(%{role: "admin", email: "quill-admin@example.test"})
    {:ok, _} = Mydia.Accounts.link_oidc_identity(admin, "sub-admin", "oidc")

    Mix.Tasks.Mydia.DeleteAdmin.run(["--email=quill-admin@example.test"])

    assert_received {:mix_shell, :info, ["  - quill-admin@example.test (Local + SSO)"]}
  end
end
