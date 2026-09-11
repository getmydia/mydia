defmodule Mydia.RemoteAccess.ClaimCodeDisabledTest do
  # async: false - :persistent_term is global and is not rolled back by the
  # Ecto sandbox, so a cached value from one test would leak into the next.
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess

  setup do
    reset_remote_access()
    on_exit(&reset_remote_access/0)

    user =
      Mydia.Repo.insert!(%Mydia.Accounts.User{
        username: "pairing_user_#{System.unique_integer([:positive])}",
        email: "pairing_#{System.unique_integer([:positive])}@example.com",
        role: "user"
      })

    %{user: user}
  end

  test "generate_claim_code/1 returns {:error, :disabled} without contacting the relay",
       %{user: user} do
    set_remote_access(false)

    assert {:error, :disabled} = RemoteAccess.generate_claim_code(user.id)
  end
end
