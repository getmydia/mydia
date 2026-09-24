defmodule Mydia.Accounts.RecoveryCodeTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.{RecoveryCode, User}
  alias Mydia.Repo

  test "users carry nullable TOTP columns" do
    user = user_fixture()

    assert %User{totp_secret_encrypted: nil, totp_enabled_at: nil, totp_last_used_at: nil} =
             Repo.get!(User, user.id)
  end

  test "totp_changeset/2 writes only TOTP fields" do
    user = user_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset =
      User.totp_changeset(user, %{
        totp_secret_encrypted: "cipher",
        totp_enabled_at: now,
        role: "admin"
      })

    updated = Repo.update!(changeset)

    assert updated.totp_secret_encrypted == "cipher"
    assert updated.totp_enabled_at == now
    assert updated.role == user.role
  end

  test "recovery codes are deleted with their user" do
    user = user_fixture()

    Repo.insert!(%RecoveryCode{user_id: user.id, code_hash: "hash"})
    Repo.delete!(user)

    assert Repo.aggregate(RecoveryCode, :count) == 0
  end
end
