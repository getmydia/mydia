defmodule Mydia.Accounts.PasskeyTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Passkey
  alias Mydia.Repo

  @cose_key %{1 => 2, 3 => -7, -1 => 1, -2 => <<1::256>>, -3 => <<2::256>>}

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        credential_id: "cred-#{System.unique_integer([:positive])}",
        public_key: @cose_key,
        rp_id: "mydia.test",
        sign_count: 0,
        aaguid: nil,
        transports: ["internal"],
        name: "Laptop"
      },
      overrides
    )
  end

  defp insert_passkey(user, overrides \\ %{}) do
    %Passkey{user_id: user.id} |> Passkey.create_changeset(attrs(overrides)) |> Repo.insert()
  end

  test "stores the COSE key and transports and reads them back" do
    user = user_fixture()
    {:ok, passkey} = insert_passkey(user)

    passkey = Repo.get!(Passkey, passkey.id)
    assert Passkey.cose_key(passkey) == @cose_key
    assert Passkey.transports(passkey) == ["internal"]
  end

  test "blank or missing name falls back to Passkey" do
    user = user_fixture()
    {:ok, passkey} = insert_passkey(user, %{name: "   "})
    assert passkey.name == "Passkey"

    {:ok, passkey} = insert_passkey(user, %{name: nil})
    assert passkey.name == "Passkey"
  end

  test "names longer than 100 characters are rejected" do
    user = user_fixture()
    assert {:error, changeset} = insert_passkey(user, %{name: String.duplicate("a", 101)})
    assert %{name: [_]} = errors_on(changeset)
  end

  test "credential ids are unique" do
    user = user_fixture()
    {:ok, _} = insert_passkey(user, %{credential_id: "same"})
    assert {:error, changeset} = insert_passkey(user_fixture(), %{credential_id: "same"})
    assert %{credential_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "rename_changeset trims and validates" do
    user = user_fixture()
    {:ok, passkey} = insert_passkey(user)

    assert {:ok, renamed} =
             passkey |> Passkey.rename_changeset(%{"name" => "  Phone "}) |> Repo.update()

    assert renamed.name == "Phone"

    assert {:error, _} = passkey |> Passkey.rename_changeset(%{"name" => ""}) |> Repo.update()
  end

  test "deleting the user deletes their passkeys" do
    user = user_fixture()
    {:ok, passkey} = insert_passkey(user)

    Repo.delete!(user)
    refute Repo.get(Passkey, passkey.id)
  end

  test "a malformed stored key decodes to an empty map instead of raising" do
    assert Passkey.cose_key(%Passkey{public_key: "not a term"}) == %{}
    assert Passkey.transports(%Passkey{transports: "nope"}) == []
  end
end
